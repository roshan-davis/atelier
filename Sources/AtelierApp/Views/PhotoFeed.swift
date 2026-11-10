import AppKit
import AtelierCore
import IOSurface
import QuartzCore

/// Hands the Develop photo view its live frames directly, without SwiftUI and without the main
/// thread: during a slider drag each render lands in a GPU surface (`DisplaySurfaces`) that the
/// render queue itself puts on the view's frame layer (`LiveFrameSink`), so a frame is neither
/// read back to the CPU, nor sent through a SwiftUI update of the window, nor kept waiting while
/// the main thread is busy (the knob, panels and histogram updating). When the edit rests,
/// `DevelopController` publishes the ordinary image as before, so what is shown at rest (and
/// every other view of the photo) is unchanged.
///
/// Only the single-photo view (and the Masking view, which shows the same render) attaches;
/// compare views, crop and the other tools keep the ordinary path.
@MainActor
final class PhotoFeed {
    enum Fallback { case liveFramesOff, poolFull }

    struct RenderTiming {
        let count: Int
        let readyAt: CFTimeInterval
        let duration: CFTimeInterval
        let queueWait: CFTimeInterval
        /// When the render queue put the frame on the layer; nil for an ordinary image, which
        /// reaches the layer on the main thread.
        var shownAt: CFTimeInterval? = nil
    }

    private let onFrame: ((RenderTiming) -> Void)?

    init(onFrame: ((RenderTiming) -> Void)? = nil) { self.onFrame = onFrame }

    /// Puts frames on screen from the render queue; see `LiveFrameSink`.
    nonisolated let sink = LiveFrameSink()
    private weak var view: ZoomScrollView?
    /// The image the controller published last, with the render count it was made from.
    private var published: (id: ObjectIdentifier, count: Int, timing: RenderTiming?)?

    /// A view is showing the photo and can take frames.
    var isAttached: Bool { view != nil }

    func attach(_ view: ZoomScrollView) {
        guard self.view !== view else { return }
        sink.setTarget(view.liveFrameLayer, imageSize: view.liveImageSize)
        self.view = view
    }

    func detach(_ view: ZoomScrollView) {
        guard self.view === view else { return }
        sink.setTarget(nil, imageSize: nil)
        self.view = nil
    }

    /// The render queue put render `timing.count` on screen (`LiveFrameSink.present`).
    func frameShown(_ timing: RenderTiming) {
        onFrame?(timing)
    }

    /// The controller published `image`, made from render `count`.
    func published(_ image: NSImage, count: Int, timing: RenderTiming? = nil) {
        published = (ObjectIdentifier(image), count, timing)
    }

    /// Whether `image` is a published render older than the frame on screen, which must not
    /// replace it (SwiftUI can pass an image along after a newer frame has been drawn).
    func isOlderThanShown(_ image: NSImage) -> Bool {
        guard let published, published.id == ObjectIdentifier(image) else { return false }
        return published.count < sink.shownCount
    }

    /// `view` has put an ordinary image on screen: the frame layer is cleared, unless it holds a
    /// newer frame, and later frames must have the image's shape.
    func imageShown(_ image: NSImage?, in view: ZoomScrollView) {
        guard self.view === view else { return }
        let count = image.flatMap { image in
            published.flatMap { $0.id == ObjectIdentifier(image) ? $0.count : nil }
        }
        sink.imageShown(size: image?.size, count: count)
        if let image, let published, published.id == ObjectIdentifier(image), let timing = published.timing {
            onFrame?(timing)
        }
    }
}

/// The photo view's frame layer, fed from the render queue. `present` puts a frame on the layer
/// in its own Core Animation transaction on the calling (render) thread, so the frame reaches
/// the screen at the next refresh whatever the main thread is doing; LightCraft draws its
/// renders the same way, at the next frame, independent of its UI work (see
/// reports/develop-slider-smoothness-design-2026-11-10.md, D1).
///
/// The main thread only changes what the frames must match (`setTarget`, `imageShown`,
/// `invalidate`). Its lock is never held across a Core Animation commit, so a main thread
/// committing its own changes can't wait on the render queue, nor the other way round.
final class LiveFrameSink: @unchecked Sendable {
    enum Outcome {
        /// On screen.
        case shown
        /// Another shape than the image on screen (an Aspect or crop change): render it the
        /// ordinary way, which resizes the view.
        case wrongShape
        /// Made for an earlier state (another photo, the Before view, crop) or older than what is
        /// on screen; dropped.
        case stale
        /// No photo view to show it in.
        case noView
    }

    private let lock = NSLock()
    private weak var layer: CALayer?
    /// The size of the ordinary image on screen; frames must have its shape.
    private var imageSize: CGSize?
    private var epoch = 0
    private var shown: (surface: IOSurface, pool: DisplaySurfaces)?
    private var shownCountValue = -1
    /// Frames from renders up to this count are older than the ordinary image on screen.
    private var floor = -1

    /// The render count of the newest frame put on screen.
    var shownCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return shownCountValue
    }

    /// What a render requested now must carry to be shown (`present`).
    var currentEpoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// Frames requested before this call are dropped: the photo, the Before view, the crop tool
    /// or a slider's Option view changed.
    func invalidate() {
        lock.lock()
        epoch += 1
        lock.unlock()
    }

    /// The layer frames go on, and the size of the image on screen. Clears a frame on the old layer.
    func setTarget(_ layer: CALayer?, imageSize: CGSize?) {
        lock.lock()
        let old = shown
        let oldLayer = self.layer
        shown = nil
        self.layer = layer
        self.imageSize = imageSize
        epoch += 1
        lock.unlock()
        if let oldLayer, oldLayer !== layer || old != nil { Self.clear(oldLayer) }
        if let old { old.pool.checkIn(old.surface) }
    }

    /// An ordinary image of `size`, published from render `count` (nil when it isn't a render,
    /// e.g. the cached preview), is on screen. Called on the main thread.
    func imageShown(size: CGSize?, count: Int?) {
        lock.lock()
        imageSize = size
        // A newer frame stays on top of an older image.
        if let count, count < shownCountValue {
            lock.unlock()
            return
        }
        floor = max(floor, count ?? shownCountValue)
        let old = shown
        shown = nil
        let target = layer
        lock.unlock()
        if let target { Self.clear(target) }
        if let old { old.pool.checkIn(old.surface) }
    }

    /// Puts `surface`, render `count` requested at `epoch`, on screen, on the calling thread.
    /// The surface is returned to `pool` whenever it isn't shown.
    func present(_ surface: IOSurface, count: Int, epoch: Int, pool: DisplaySurfaces) -> Outcome {
        lock.lock()
        let outcome: Outcome
        if epoch != self.epoch || count <= shownCountValue || count <= floor {
            outcome = .stale
        } else if layer == nil {
            outcome = .noView
        } else if let imageSize, Self.fits(surface, imageSize) {
            outcome = .shown
        } else {
            outcome = .wrongShape
        }
        guard outcome == .shown, let target = layer else {
            lock.unlock()
            pool.checkIn(surface)
            return outcome == .shown ? .noView : outcome
        }
        let old = shown
        shown = (surface, pool)
        shownCountValue = count
        lock.unlock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.contents = surface
        target.isHidden = false
        CATransaction.commit()
        // This thread has no run loop to commit for it.
        CATransaction.flush()
        // Reused only once the window server has let go of it (`DisplaySurfaces.checkOut`).
        if let old { old.pool.checkIn(old.surface) }
        return .shown
    }

    /// The image's height at the frame's width is within rounding of a pixel when they are the
    /// same photo at two sizes (the proxy and the full-size render).
    private static func fits(_ surface: IOSurface, _ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, surface.width > 0, surface.height > 0 else { return false }
        let expectedHeight = size.height * CGFloat(surface.width) / size.width
        return abs(CGFloat(surface.height) - expectedHeight) <= 1.5
    }

    private static func clear(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        layer.isHidden = true
        CATransaction.commit()
    }
}
