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
/// The single-photo view, the Masking view (which shows the same render) and the After photo of
/// the Before/After compare views (side by side and the split slider) attach; crop and the other
/// tools keep the ordinary path. Compare views used to take the ordinary path too, so every frame
/// of a drag there was read back to the CPU and sent through a SwiftUI update of the whole window,
/// which Rosh saw as the photo freezing while editing in a compare view (Nov 10, 2026).
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
    /// Puts the sharp visible part of a zoomed photo over the live frames; see `DetailFrameSink`.
    nonisolated let detail = DetailFrameSink()
    private weak var view: ZoomScrollView?
    /// The image the controller published last, with the render count it was made from.
    private var published: (id: ObjectIdentifier, count: Int, timing: RenderTiming?)?

    /// A view is showing the photo and can take frames.
    var isAttached: Bool { view != nil }
    /// The view frames go to.
    var attachedView: ZoomScrollView? { view }

    func attach(_ view: ZoomScrollView) {
        guard self.view !== view else { return }
        sink.setTarget(view.liveFrameLayer, imageSize: view.liveImageSize)
        detail.setTarget(view.detailFrameLayer)
        self.view = view
    }

    func detach(_ view: ZoomScrollView) {
        guard self.view === view else { return }
        sink.setTarget(nil, imageSize: nil)
        detail.setTarget(nil)
        self.view = nil
    }

    /// Where a zoomed detail frame would go now; nil at Fit, or with no view attached.
    var detailTarget: ZoomedDetailTarget? { view?.detailTarget() }

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

/// Where a zoomed detail frame (`ZoomedDetail`) goes: the visible part of the photo, 0...1 from
/// the top-left, its size in screen pixels, and the same rectangle in the photo view's canvas
/// (points) and in its layer, where the frame is placed. Read on the main thread
/// (`ZoomScrollView.detailTarget`).
struct ZoomedDetailTarget: Equatable, Sendable {
    var visible: CGRect
    var pixels: CGSize
    var canvasRect: CGRect
    var layerRect: CGRect
}

/// The photo view's detail layer, over the live frames: while a slider drags on a zoomed photo,
/// the render queue for the full-size photo puts the visible part, rendered sharp at the screen's
/// resolution, on it (`DevelopController.scheduleZoomedDetail`). Like `LiveFrameSink`, each frame
/// goes on in its own Core Animation transaction from the rendering thread, and the main thread
/// only says what frames must match (`invalidate`, `clear`).
///
/// A frame is dropped, and the one on screen cleared, when the view pans or zooms (its rectangle
/// no longer covers what is shown), when the photo or what it shows changes (`invalidate`), and
/// once an ordinary image as sharp as the frame is on screen (the full-size render at rest).
final class DetailFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var layer: CALayer?
    private var epoch = 0
    private var shown: (surface: IOSurface, pool: DisplaySurfaces, canvasRect: CGRect, density: CGFloat)?
    private var shownCount = -1

    /// What a detail render requested now must carry to be shown.
    var currentEpoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// The canvas rectangle of the frame on screen, if any.
    var shownCanvasRect: CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return shown?.canvasRect
    }

    func setTarget(_ layer: CALayer?) {
        lock.lock()
        let oldLayer = self.layer
        self.layer = layer
        lock.unlock()
        if oldLayer !== layer { clear(oldLayer) }
    }

    /// Frames requested before this call are dropped, and the one on screen goes.
    func invalidate() {
        lock.lock()
        epoch += 1
        lock.unlock()
        clear()
    }

    /// An ordinary image `pixelsPerPoint` dense (image pixels per canvas point) is on screen:
    /// the frame goes if the image is at least as sharp, so the full-size render replaces it, while
    /// the settled proxy (softer) leaves it on until then.
    func imageShown(pixelsPerPoint: CGFloat) {
        lock.lock()
        let sharper = shown.map { pixelsPerPoint >= $0.density * 0.95 } ?? false
        if sharper { epoch += 1 }
        lock.unlock()
        if sharper { clear() }
    }

    /// The view panned or zoomed to show `canvasRect`: a frame made for another rectangle goes.
    func visibleChanged(to canvasRect: CGRect?) {
        lock.lock()
        let moved = shown.map { shown in
            guard let canvasRect else { return true }
            return abs(shown.canvasRect.minX - canvasRect.minX) > 0.5 || abs(shown.canvasRect.minY - canvasRect.minY) > 0.5
                || abs(shown.canvasRect.width - canvasRect.width) > 0.5 || abs(shown.canvasRect.height - canvasRect.height) > 0.5
        } ?? false
        if moved { epoch += 1 }
        lock.unlock()
        if moved { clear() }
    }

    /// Puts `surface`, detail render `count` requested at `epoch`, on screen over `target`, on the
    /// calling thread. True when shown; otherwise the surface is back in `pool`.
    func present(_ surface: IOSurface, count: Int, epoch: Int, target: ZoomedDetailTarget, pool: DisplaySurfaces) -> Bool {
        lock.lock()
        guard epoch == self.epoch, count > shownCount, let layer else {
            lock.unlock()
            pool.checkIn(surface)
            return false
        }
        let old = shown
        let density = CGFloat(surface.width) / max(1, target.canvasRect.width)
        shown = (surface, pool, target.canvasRect, density)
        shownCount = count
        lock.unlock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: target.layerRect.size)
        layer.position = CGPoint(x: target.layerRect.midX, y: target.layerRect.midY)
        layer.contents = surface
        layer.isHidden = false
        CATransaction.commit()
        // This thread has no run loop to commit for it.
        CATransaction.flush()
        if let old { old.pool.checkIn(old.surface) }
        return true
    }

    /// Takes the frame off screen and lets its pool go (it holds a screen's worth of pixels).
    func clear() {
        lock.lock()
        let old = shown
        shown = nil
        shownCount = -1
        let target = layer
        lock.unlock()
        clear(target)
        if let old {
            old.pool.checkIn(old.surface)
            old.pool.drain()
        }
    }

    private func clear(_ layer: CALayer?) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        layer.isHidden = true
        CATransaction.commit()
    }
}
