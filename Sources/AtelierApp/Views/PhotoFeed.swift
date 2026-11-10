import AppKit
import AtelierCore
import IOSurface

/// Hands the Develop photo view its live frames directly, without SwiftUI: during a slider drag
/// each render lands in a GPU surface (`DisplaySurfaces`) that the view's layer shows as is, so
/// a frame is neither read back to the CPU nor sent through a SwiftUI update of the window.
/// When the edit rests, `DevelopController` publishes the ordinary image as before, so what is
/// shown at rest (and every other view of the photo) is unchanged.
///
/// Only the single-photo view (and the Masking view, which shows the same render) attaches;
/// compare views, crop and the other tools keep the ordinary path.
@MainActor
final class PhotoFeed {
    struct RenderTiming {
        let count: Int
        let readyAt: CFTimeInterval
        let duration: CFTimeInterval
        let queueWait: CFTimeInterval
    }

    private let onFrame: ((RenderTiming) -> Void)?

    init(onFrame: ((RenderTiming) -> Void)? = nil) { self.onFrame = onFrame }


    private weak var view: ZoomScrollView?
    /// The surface on screen now, and the pool it came from.
    private var shown: (surface: IOSurface, pool: DisplaySurfaces)?
    /// The render count of the newest frame put on screen.
    private(set) var shownCount = -1
    /// The image the controller published last, with the render count it was made from.
    private var published: (id: ObjectIdentifier, count: Int, timing: RenderTiming?)?

    /// A view is showing the photo and can take frames.
    var isAttached: Bool { view != nil }

    func attach(_ view: ZoomScrollView) {
        guard self.view !== view else { return }
        releaseShown()
        self.view = view
    }

    func detach(_ view: ZoomScrollView) {
        guard self.view === view else { return }
        releaseShown()
        self.view = nil
    }

    /// Puts a live frame on screen. False when it can't be shown (no view, or its shape differs
    /// from the photo on screen, e.g. after an Aspect change); the surface is returned to the
    /// pool and the frame must be shown the ordinary way.
    func show(_ surface: IOSurface, count: Int, from pool: DisplaySurfaces, timing: RenderTiming? = nil) -> Bool {
        guard let view, view.showFrame(surface) else {
            pool.checkIn(surface)
            return false
        }
        releaseShown()
        shown = (surface, pool)
        shownCount = max(shownCount, count)
        if let timing { onFrame?(timing) }
        return true
    }

    /// The controller published `image`, made from render `count`.
    func published(_ image: NSImage, count: Int, timing: RenderTiming? = nil) {
        published = (ObjectIdentifier(image), count, timing)
    }

    /// Whether `image` is a published render older than the frame on screen, which must not
    /// replace it (SwiftUI can pass an image along after a newer frame has been drawn).
    func isOlderThanShown(_ image: NSImage) -> Bool {
        guard let published, published.id == ObjectIdentifier(image) else { return false }
        return published.count < shownCount
    }

    /// `view` has put an ordinary image on screen in place of the frame.
    func imageShown(_ image: NSImage?, in view: ZoomScrollView) {
        guard self.view === view else { return }
        releaseShown()
        if let image, let published, published.id == ObjectIdentifier(image), let timing = published.timing {
            onFrame?(timing)
        }
    }

    private func releaseShown() {
        if let shown { shown.pool.checkIn(shown.surface) }
        shown = nil
    }
}
