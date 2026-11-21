import AppKit
import AtelierCore
import Foundation
import IOSurface

/// A zoomed detail frame handed to `fullQueue` (`DevelopController.scheduleZoomedDetail`).
struct ZoomedDetailRequest: @unchecked Sendable {
    /// Detail renders slower than this (in seconds) three times in a row give up for the drag.
    /// Sharp frames that trail a little are what Rosh asked for (Nov 21, 2026: still low
    /// resolution on a heavily edited photo, whose 2398 × 1456 px frames took 74-93 ms against
    /// a first limit of 70 ms); only frames this slow (under 7 a second) are worse than the proxy.
    static let slowLimit: CFTimeInterval = 0.150

    let session: DevelopSession
    let settings: DevelopSettings
    let target: ZoomedDetailTarget
    let clipping: (shadows: Bool, highlights: Bool)
    let count: Int
    let epoch: Int
    let assetID: Int64?
    let sink: DetailFrameSink
    let surfaces: DisplaySurfaces
    let stats: LockedValue<ZoomedDetailStats>
}

/// One drag's detail frames (`DevelopController.detailStats`).
struct ZoomedDetailStats: Sendable {
    var rendered = 0
    var shown = 0
    var totalTime: CFTimeInterval = 0
    var maxTime: CFTimeInterval = 0
    var slowInARow = 0
    var pixels = CGSize.zero
}

/// Sharp zoomed slider drags (Rosh, Nov 21, 2026: "why all the values are applying on less
/// resolution and coming back to full resolution when it finishes?"). Zoomed past Fit the proxy
/// (2560 px) is stretched over the screen, and the full-size render waits for the drag to rest,
/// because rendering the whole 24-45 MP photo per tick took 55-170 ms and stuttered (AT-039 D4).
/// Like Photoshop, each tick now also renders just the part on screen, at the screen's
/// resolution, from the full-size photo already open for the zoom (`fullSession`), and puts it
/// over the proxy's frame (`DetailFrameSink`). The proxy still renders every tick (the histogram
/// and a frame under the detail when panning come from it).
extension DevelopController {
    /// Zoomed in with nothing in the way of detail frames (a tool, a compare view, frames too
    /// slow this drag). `displayImage` keeps the full-size image under them then.
    var usesZoomedDetail: Bool {
        wantsFullResolution && !detailGaveUp && compareMode == .off && sliderPreview == nil && !showingBefore
            && !isCropping && !isGuiding && !isLensBlurring && !(isMasking && showMaskOverlay)
    }

    /// Asks for a detail frame of `settings` if the photo is zoomed in further than the proxy
    /// has pixels for. Called with every live (direct) proxy render. True when one was asked for.
    @discardableResult
    func scheduleZoomedDetail(_ settings: DevelopSettings, clipping: (shadows: Bool, highlights: Bool)) -> Bool {
        guard wantsFullResolution else { return false }
        let target = photoFeed.detailTarget
        let skip: String? = {
            if detailGaveUp { return "frames too slow this drag" }
            if compareMode != .off { return "compare view" }
            if sliderPreview != nil || showingBefore { return "Before or an Option view" }
            if isCropping || isGuiding || isLensBlurring || (isMasking && showMaskOverlay) { return "a tool is open" }
            if fullSession == nil { return "full-size photo not open yet" }
            guard let proxyWidth = image?.size.width else { return "no proxy" }
            guard let target else { return "whole photo in view" }
            if ZoomedDetail.isSharpEnough(imageWidth: proxyWidth, visibleWidth: target.visible.width,
                                          screenPixels: target.pixels.width) { return "proxy sharp enough" }
            return nil
        }()
        if skip != detailSkipReason {
            detailSkipReason = skip
            if let skip { DevelopTimingLog.shared.log(assetID, "zoomed detail off: \(skip)") }
        }
        guard skip == nil, let session = fullSession, let target else { return false }
        detailCount += 1
        let request = ZoomedDetailRequest(session: session, settings: settings, target: target, clipping: clipping,
                                          count: detailCount, epoch: photoFeed.detail.currentEpoch, assetID: assetID,
                                          sink: photoFeed.detail, surfaces: detailSurfaces, stats: detailStats)
        if detailJob.submit(request) {
            let job = detailJob
            let queue = fullQueue
            queue.async { Self.renderZoomedDetailNext(job: job, on: queue, controller: self) }
        }
        return true
    }

    /// The edit rested: logs the drag's detail frames, and the next drag tries them again.
    func zoomedDetailSettled() {
        detailGaveUp = false
        var stats = ZoomedDetailStats()
        detailStats.update { swap(&$0, &stats) }
        detailSkipReason = nil
        guard stats.rendered > 0 else { return }
        let average = stats.totalTime / Double(stats.rendered)
        DevelopTimingLog.shared.log(assetID, "zoomed detail: \(stats.shown) of \(stats.rendered) frames shown, "
            + "\(Int(stats.pixels.width))×\(Int(stats.pixels.height)) px, "
            + "average \(Int((average * 1000).rounded())) ms, slowest \(Int((stats.maxTime * 1000).rounded())) ms")
    }

    private nonisolated static func renderZoomedDetailNext(job: LatestJob<ZoomedDetailRequest>, on queue: DispatchQueue,
                                                          controller: DevelopController) {
        guard let request = job.take() else { return }
        // Panned, zoomed or changed meanwhile: drop it without rendering.
        if request.epoch == request.sink.currentEpoch {
            let began = CACurrentMediaTime()
            let surface = RenderSignposts.measure("Zoomed detail render") {
                request.session.renderZoomedDetail(request.settings, visible: request.target.visible,
                                                   pixels: request.target.pixels,
                                                   shadowClipping: request.clipping.shadows,
                                                   highlightClipping: request.clipping.highlights,
                                                   surfaces: request.surfaces)
            }
            let took = CACurrentMediaTime() - began
            var shown = false
            if let surface {
                shown = request.sink.present(surface, count: request.count, epoch: request.epoch,
                                             target: request.target, pool: request.surfaces)
            }
            var giveUp = false
            request.stats.update { stats in
                stats.rendered += 1
                if shown { stats.shown += 1 }
                stats.totalTime += took
                stats.maxTime = max(stats.maxTime, took)
                stats.pixels = request.target.pixels
                // A drag's first frame may build Core Image programs for the full-size photo.
                if stats.rendered > 1 {
                    stats.slowInARow = took > ZoomedDetailRequest.slowLimit ? stats.slowInARow + 1 : 0
                }
                giveUp = stats.slowInARow == 3
            }
            if giveUp {
                DevelopTimingLog.shared.log(request.assetID, "zoomed detail frames too slow "
                    + "(\(Int((took * 1000).rounded())) ms, \(Int(request.target.pixels.width))×\(Int(request.target.pixels.height)) px): "
                    + "proxy only until the edit rests")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        controller.detailGaveUp = true
                        controller.photoFeed.detail.invalidate()
                    }
                }
            }
        }
        queue.async { Self.renderZoomedDetailNext(job: job, on: queue, controller: controller) }
    }
}
