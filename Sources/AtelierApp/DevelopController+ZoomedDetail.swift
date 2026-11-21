import AppKit
import AtelierCore
import Foundation
import IOSurface

/// A zoomed detail frame handed to `fullQueue` (`DevelopController.scheduleZoomedDetail`).
struct ZoomedDetailRequest: @unchecked Sendable {
    /// A detail render slower than this (in seconds) twice in a row gives up for the drag: the
    /// sharp frames would then trail the proxy's by several of its frames.
    static let slowLimit: CFTimeInterval = 0.070

    let session: DevelopSession
    let settings: DevelopSettings
    let target: ZoomedDetailTarget
    let clipping: (shadows: Bool, highlights: Bool)
    let count: Int
    let epoch: Int
    let assetID: Int64?
    let sink: DetailFrameSink
    let surfaces: DisplaySurfaces
    let slowFrames: LockedValue<Int>
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
    /// Asks for a detail frame of `settings` if the photo is zoomed in further than the proxy
    /// has pixels for. Called with every live (direct) proxy render.
    func scheduleZoomedDetail(_ settings: DevelopSettings, clipping: (shadows: Bool, highlights: Bool)) {
        guard wantsFullResolution, !detailGaveUp, compareMode == .off, sliderPreview == nil, !showingBefore,
              !isCropping, !isGuiding, !isLensBlurring, !(isMasking && showMaskOverlay),
              let session = fullSession, let proxyWidth = image?.size.width,
              let target = photoFeed.detailTarget,
              !ZoomedDetail.isSharpEnough(imageWidth: proxyWidth, visibleWidth: target.visible.width,
                                          screenPixels: target.pixels.width) else { return }
        detailCount += 1
        let request = ZoomedDetailRequest(session: session, settings: settings, target: target, clipping: clipping,
                                          count: detailCount, epoch: photoFeed.detail.currentEpoch, assetID: assetID,
                                          sink: photoFeed.detail, surfaces: detailSurfaces,
                                          slowFrames: detailSlowFrames)
        guard detailJob.submit(request) else { return }
        let job = detailJob
        let queue = fullQueue
        queue.async { Self.renderZoomedDetailNext(job: job, on: queue, controller: self) }
    }

    /// The edit rested: the full-size render takes over, and the next drag tries detail frames again.
    func zoomedDetailSettled() {
        detailGaveUp = false
        detailSlowFrames.value = 0
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
            if let surface {
                _ = request.sink.present(surface, count: request.count, epoch: request.epoch,
                                         target: request.target, pool: request.surfaces)
            }
            var slow = 0
            request.slowFrames.update { count in
                count = took > ZoomedDetailRequest.slowLimit ? count + 1 : 0
                slow = count
            }
            if slow == 2 {
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
