import AppKit
import AtelierCore
import Foundation
import IOSurface

/// A sharp visible-area render handed to `fullQueue` (`DevelopController.scheduleSharpRegion`).
struct SharpRegionRequest: @unchecked Sendable {
    let session: DevelopSession
    let settings: DevelopSettings
    let cropping: Bool
    let preview: SliderPreview?
    let clipping: (shadows: Bool, highlights: Bool)
    let photo: Int
    let revision: Int
    /// The render it goes with (`DevelopController.renderCount`), for Frame Diagnostics.
    let count: Int
    let target: PhotoDisplay.RegionTarget
    let assetID: Int64?
    let display: PhotoDisplay
    let surfaces: DisplaySurfaces
    let stats: LockedValue<SharpRegionStats>
    let queuedAt: CFTimeInterval
}

/// One edit's visible-area renders, logged when it rests (`DevelopController.sharpRegionsSettled`).
struct SharpRegionStats: Sendable {
    var rendered = 0
    var shown = 0
    var totalTime: CFTimeInterval = 0
    var maxTime: CFTimeInterval = 0
    var pixels = CGSize.zero
}

/// Sharp zoomed photos (Rosh, Nov 21, 2026: "why all the values are applying on less resolution
/// and coming back to full resolution when it finishes?"; "when I click on a new image, it is
/// drawing low resolution then drawing the high resolution"). Zoomed in further than the 2560 px
/// proxy has pixels for, the part of the photo on screen is rendered from the full-size photo at
/// the screen's resolution (`ZoomedDetail`), for every edit and for a newly opened photo, and
/// offered to the photo view's one rule (`PhotoDisplay`, `SharpDisplay`), which shows it over the
/// whole-photo image. During a drag it is the only render: the proxy renders once the edit rests.
extension DevelopController {
    /// Asks for a sharp render of the visible part of `settings`, if the view needs one (zoomed in
    /// past what the proxy has pixels for, the full-size photo open). True when one was asked for.
    func scheduleSharpRegion(_ settings: DevelopSettings, cropping: Bool, preview: SliderPreview?,
                             clipping: (shadows: Bool, highlights: Bool), photo: Int, revision: Int,
                             count: Int) -> Bool {
        guard wantsFullResolution, let display, let session = fullSession else { return false }
        let proxyWidth = Double(image?.size.width ?? CGFloat(Self.proxySize))
        guard let target = display.regionTarget(over: proxyWidth) else { return false }
        let request = SharpRegionRequest(session: session, settings: settings, cropping: cropping, preview: preview,
                                         clipping: clipping, photo: photo, revision: revision, count: count,
                                         target: target, assetID: assetID, display: display,
                                         surfaces: regionSurfaces, stats: regionStats, queuedAt: CACurrentMediaTime())
        if regionJob.submit(request) {
            let job = regionJob
            let queue = fullQueue
            queue.async { Self.renderSharpRegionNext(job: job, on: queue, controller: self) }
        }
        return true
    }

    /// For a photo just opened zoomed in: what its first sharp render of the visible part needs,
    /// rendered on `fullQueue` as soon as its full-size photo is open (`renderOpeningRegion`).
    func sharpOpenRequest(_ settings: DevelopSettings, clipping: (shadows: Bool, highlights: Bool),
                          photo: Int, revision: Int) -> SharpOpenRequest? {
        guard let display else { return nil }
        return SharpOpenRequest(settings: settings, clipping: clipping, photo: photo, revision: revision,
                                display: display, surfaces: regionSurfaces)
    }

    /// The edit rested: logs its visible-area renders.
    func sharpRegionsSettled() {
        var stats = SharpRegionStats()
        regionStats.update { swap(&$0, &stats) }
        guard stats.rendered > 0 else { return }
        let average = stats.totalTime / Double(stats.rendered)
        DevelopTimingLog.shared.log(assetID, "zoomed sharp area: \(stats.shown) of \(stats.rendered) renders shown, "
            + "\(Int(stats.pixels.width))×\(Int(stats.pixels.height)) px, "
            + "average \(Int((average * 1000).rounded())) ms, slowest \(Int((stats.maxTime * 1000).rounded())) ms")
    }

    /// Renders the visible part of a photo just opened, on `fullQueue`, with its full-size `session`.
    nonisolated static func renderOpeningRegion(_ request: SharpOpenRequest, session: DevelopSession, assetID: Int64?) {
        guard let target = request.display.regionTarget(over: Double(proxySize)) else { return }
        let epoch = request.display.currentEpoch
        let began = CACurrentMediaTime()
        guard let surface = RenderSignposts.measure("Zoomed open sharp area", {
            session.renderZoomedDetail(request.settings, visible: target.visible, pixels: target.pixels,
                                       shadowClipping: request.clipping.shadows,
                                       highlightClipping: request.clipping.highlights, surfaces: request.surfaces)
        }) else { return }
        let outcome = request.display.offer(surface: surface, pool: request.surfaces, photo: request.photo,
                                            revision: request.revision, region: target.visible, epoch: epoch)
        DevelopTimingLog.shared.log(assetID, "zoomed open: sharp area \(Int(target.pixels.width))×\(Int(target.pixels.height)) px "
            + "in \(Int(((CACurrentMediaTime() - began) * 1000).rounded())) ms, \(outcome)")
    }

    private nonisolated static func renderSharpRegionNext(job: LatestJob<SharpRegionRequest>, on queue: DispatchQueue,
                                                         controller: DevelopController) {
        guard let request = job.take() else { return }
        let began = CACurrentMediaTime()
        let surface = RenderSignposts.measure("Zoomed sharp area render") {
            request.session.renderZoomedDetail(request.settings, cropping: request.cropping, preview: request.preview,
                                               visible: request.target.visible, pixels: request.target.pixels,
                                               shadowClipping: request.clipping.shadows,
                                               highlightClipping: request.clipping.highlights,
                                               surfaces: request.surfaces)
        }
        let readyAt = CACurrentMediaTime()
        var outcome: PhotoDisplay.Outcome?
        if let surface {
            outcome = request.display.offer(surface: surface, pool: request.surfaces, photo: request.photo,
                                            revision: request.revision, region: request.target.visible,
                                            epoch: request.display.currentEpoch)
        }
        let took = readyAt - began
        request.stats.update { stats in
            stats.rendered += 1
            if outcome == .shown { stats.shown += 1 }
            stats.totalTime += took
            stats.maxTime = max(stats.maxTime, took)
            stats.pixels = request.target.pixels
        }
        if outcome == .shown {
            let timing = PhotoFeed.RenderTiming(count: request.count, readyAt: readyAt, duration: took,
                                               queueWait: max(0, began - request.queuedAt), shownAt: CACurrentMediaTime())
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.photoFeed.frameShown(timing) }
            }
        }
        queue.async { Self.renderSharpRegionNext(job: job, on: queue, controller: controller) }
    }
}

/// See `DevelopController.sharpOpenRequest`.
struct SharpOpenRequest: @unchecked Sendable {
    let settings: DevelopSettings
    let clipping: (shadows: Bool, highlights: Bool)
    let photo: Int
    let revision: Int
    let display: PhotoDisplay
    let surfaces: DisplaySurfaces
}
