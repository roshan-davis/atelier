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
    private weak var view: ZoomScrollView?
    /// The image the controller published last, with the render count it was made from.
    private var published: (id: ObjectIdentifier, count: Int, timing: RenderTiming?)?

    /// A view is showing the photo and can take frames.
    var isAttached: Bool { view != nil }
    /// `view` is the one taking frames.
    func isAttached(_ view: ZoomScrollView) -> Bool { self.view === view }

    /// Where a frame of only the visible part would go, at the screen's resolution
    /// (`ZoomScrollView.regionTarget`); nil at Fit or with no view.
    var regionTarget: ZoomedDetailTarget? { view?.regionTarget() }

    /// Called when the view panned or zoomed away from the frame on screen, which it then took
    /// down: the controller renders the new view.
    var onFrameLost: (() -> Void)?

    /// The view now shows `canvasRect` of its canvas (nil: nothing yet).
    func visibleChanged(to canvasRect: CGRect?, in view: ZoomScrollView) {
        guard self.view === view else { return }
        if sink.visibleChanged(to: canvasRect) { onFrameLost?() }
    }

    func attach(_ view: ZoomScrollView) {
        guard self.view !== view else { return }
        sink.setTarget(view.liveFrameLayer, imageSize: view.liveImageSize)
        sink.setLayout(whole: view.liveFrameBounds, visible: view.shownCanvasRect)
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
        let pixels = image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { CGFloat($0.width) }
        let width = view.liveFrameBounds.width
        sink.imageShown(size: image?.size, count: count,
                        pixelsPerPoint: pixels.map { width > 0 ? $0 / width : 0 })
        if let image, let published, published.id == ObjectIdentifier(image), let timing = published.timing {
            onFrame?(timing)
        }
    }
}

/// Where a frame of the visible part of a zoomed photo goes (`ZoomedDetail`): the visible part,
/// 0...1 from the top-left, its size in screen pixels, and the same rectangle in the photo view's
/// canvas (points) and in its layer. Read on the main thread (`ZoomScrollView.regionTarget`).
struct ZoomedDetailTarget: Equatable, Sendable {
    var visible: CGRect
    var pixels: CGSize
    var canvasRect: CGRect
    var layerRect: CGRect

    /// The layer rectangle of `part` of the photo (0...1 from the top-left), in the same terms
    /// as `layerRect` is of `visible`.
    func placing(_ part: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return layerRect }
        let perUnitX = layerRect.width / visible.width, perUnitY = layerRect.height / visible.height
        let originX = layerRect.minX - visible.minX * perUnitX, originY = layerRect.minY - visible.minY * perUnitY
        return CGRect(x: originX + part.minX * perUnitX, y: originY + part.minY * perUnitY,
                      width: part.width * perUnitX, height: part.height * perUnitY)
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

    /// What a frame covers: the whole photo (the proxy's render, or the full-size photo at Fit),
    /// or only the part in view, rendered at the screen's resolution from the full-size photo
    /// while zoomed in (`DevelopSession.renderZoomedDetail`). One layer shows either.
    enum Placement: Equatable, Sendable {
        case whole
        case region(ZoomedDetailTarget)
    }

    private let lock = NSLock()
    private weak var layer: CALayer?
    /// The size of the ordinary image on screen; frames must have its shape.
    private var imageSize: CGSize?
    /// The canvas's bounds (a whole frame's place) and the part of it in view (a region frame's).
    private var wholeRect = CGRect.zero
    private var visibleRect: CGRect?
    private var epoch = 0
    /// The frame on screen, where it is, and its pixels per canvas point.
    private var shown: (surface: IOSurface, pool: DisplaySurfaces, placement: Placement, density: CGFloat)?
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

    /// The canvas's bounds and the part of it in view, when a view attaches.
    func setLayout(whole: CGRect, visible: CGRect?) {
        lock.lock()
        wholeRect = whole
        visibleRect = visible
        lock.unlock()
    }

    /// The canvas was resized (another photo shape, the crop): a whole frame follows it, a frame
    /// of one part goes, as its place is gone. Called on the main thread; nothing is shown out of
    /// place in between.
    func setWhole(_ rect: CGRect) {
        lock.lock()
        wholeRect = rect
        var lost: (surface: IOSurface, pool: DisplaySurfaces)?
        let isRegion: Bool
        if let current = shown, case .region = current.placement { isRegion = true } else { isRegion = false }
        if isRegion, let current = shown {
            lost = (current.surface, current.pool)
            shown = nil
            epoch += 1
        }
        let target = layer
        lock.unlock()
        guard let target else { return }
        if let lost {
            Self.clear(target)
            lost.pool.checkIn(lost.surface)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            target.bounds = CGRect(origin: .zero, size: rect.size)
            target.position = CGPoint(x: rect.midX, y: rect.midY)
            CATransaction.commit()
        }
    }

    /// The view now shows `canvasRect`: a frame of another part is taken down. True when one was.
    func visibleChanged(to canvasRect: CGRect?) -> Bool {
        lock.lock()
        visibleRect = canvasRect
        var lost: (surface: IOSurface, pool: DisplaySurfaces)?
        if let current = shown, case .region(let target) = current.placement,
           !Self.same(target.canvasRect, canvasRect) {
            lost = (current.surface, current.pool)
            shown = nil
            epoch += 1
        }
        let target = layer
        lock.unlock()
        guard let lost else { return false }
        if let target { Self.clear(target) }
        lost.pool.checkIn(lost.surface)
        return true
    }

    /// An ordinary image of `size`, published from render `count` (nil when it isn't a render,
    /// e.g. the cached preview or the full-size image), `pixelsPerPoint` dense on the canvas, is on
    /// screen. Called on the main thread. The frame on top goes, unless it is newer, or it shows
    /// the same render sharper (the zoomed region frame over the settled proxy image): the photo
    /// never steps back to an older or softer picture.
    func imageShown(size: CGSize?, count: Int?, pixelsPerPoint: CGFloat? = nil) {
        lock.lock()
        imageSize = size
        // A newer frame stays on top of an older image.
        if let count, count < shownCountValue {
            lock.unlock()
            return
        }
        if let current = shown, let count, count == shownCountValue,
           let pixelsPerPoint, pixelsPerPoint < current.density * 0.95 {
            floor = max(floor, count)
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

    /// Puts `surface`, render `count` requested at `epoch`, on screen at `placement`, on the
    /// calling thread, in one transaction with its place: a frame is shown whole or not at all.
    /// The surface is returned to `pool` whenever it isn't shown.
    func present(_ surface: IOSurface, count: Int, epoch: Int, pool: DisplaySurfaces,
                 placement: Placement = .whole) -> Outcome {
        lock.lock()
        let outcome: Outcome
        if epoch != self.epoch || count <= shownCountValue || count <= floor {
            outcome = .stale
        } else if layer == nil {
            outcome = .noView
        } else if case .region(let region) = placement {
            // Made for the part in view when it was asked for; the view moved since.
            outcome = Self.same(region.canvasRect, visibleRect) ? .shown : .stale
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
        let place: CGRect
        switch placement {
        case .whole: place = wholeRect
        case .region(let region): place = region.layerRect
        }
        let density = CGFloat(surface.width) / max(1, place.width)
        shown = (surface, pool, placement, density)
        shownCountValue = count
        lock.unlock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.bounds = CGRect(origin: .zero, size: place.size)
        target.position = CGPoint(x: place.midX, y: place.midY)
        target.contents = surface
        target.isHidden = false
        CATransaction.commit()
        // This thread has no run loop to commit for it.
        CATransaction.flush()
        // Reused only once the window server has let go of it (`DisplaySurfaces.checkOut`).
        if let old { old.pool.checkIn(old.surface) }
        return .shown
    }

    private static func same(_ a: CGRect, _ b: CGRect?) -> Bool {
        guard let b else { return false }
        return abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5
            && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
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
