import AppKit
import AtelierCore
import IOSurface
import QuartzCore

/// Puts what `SharpDisplay` decides on the Develop photo view's layers. Every image that can go
/// on the view comes here with its `DisplayTag`, whichever path made it: the cached preview at
/// open and every ordinary image SwiftUI hands the view (`ZoomScrollView.setImage`, on the main
/// thread), live frames from the render queue, and sharp visible-area frames from the full-size
/// queue (`offer(surface:...)`, on those threads). Nothing else decides what the view shows
/// (Rosh, Nov 21, 2026: "look at this area cleanly").
///
/// Three layers: the canvas's own layer holds an ordinary image, `frameLayer` a live frame over
/// it (the base: one of the two shows), and `detailLayer` a visible-area frame over both.
///
/// Threads: the state is kept under `lock`. A render thread changes the layers in a Core
/// Animation transaction of its own after letting go of the lock, as `LiveFrameSink` does, so a
/// main thread committing its own changes never waits on a render thread or the other way round.
/// If the state changed meanwhile, the main thread puts the layers right (`sync`).
final class PhotoDisplay: @unchecked Sendable {
    enum Outcome {
        /// On screen.
        case shown
        /// Waiting for a sharper image (`SharpDisplay.Decision.wait`); shown when its time is up.
        case held
        /// Nothing new (an older edit, or the same edit no sharper than what is on screen).
        case notNeeded
        /// Another shape than the image on screen (an Aspect or crop change): render it the
        /// ordinary way, which resizes the view.
        case wrongShape
        /// Requested before the view changed what it shows (`invalidate`); dropped.
        case stale
        /// No photo view to show it in.
        case noView
    }

    /// The visible part of the photo, 0...1 across and down from the top-left, and its size in
    /// screen pixels: what a sharp visible-area render makes (`ZoomedDetail`).
    struct RegionTarget: Equatable, Sendable {
        var visible: CGRect
        var pixels: CGSize
    }

    private enum Content {
        case image(NSImage, pixelSize: CGSize?)
        case surface(IOSurface, DisplaySurfaces)

        var surface: (IOSurface, DisplaySurfaces)? {
            if case .surface(let surface, let pool) = self { return (surface, pool) }
            return nil
        }
        var image: (NSImage, CGSize?)? {
            if case .image(let image, let pixelSize) = self { return (image, pixelSize) }
            return nil
        }
    }

    private let lock = NSLock()
    private var rule = SharpDisplay()
    private var base: Content?
    private var detail: (IOSurface, DisplaySurfaces)?
    private var held: (tag: DisplayTag, content: Content)?
    private var epoch = 0
    /// Counts changes to what should be on the layers, so a render thread that changed them can
    /// tell whether another change came in while it did.
    private var changes = 0
    private weak var frameLayer: CALayer?
    private weak var detailLayer: CALayer?
    /// The size of the ordinary image on screen; whole-photo frames must have its shape.
    private var imageSize: CGSize?
    /// The photo's top-left and bottom-right corners in the canvas layer's coordinates, where
    /// visible-area frames are placed.
    private var corners: (CGPoint, CGPoint)?
    private var viewNeed = DisplayNeed.anything
    private var target: RegionTarget?
    /// A sharper image can come: off while a tool draws the photo its own way (the crop tool,
    /// guides, the mask overlay, Lens Blur), when nothing waits for one.
    private var canSharpen = true
    // Main thread only.
    private weak var view: ZoomScrollView?
    private var expiry: (deadline: TimeInterval, item: DispatchWorkItem)?

    // MARK: Main thread

    /// The view the photo is shown in; nil when none is. Starts from nothing.
    @MainActor
    func setView(_ view: ZoomScrollView?) {
        guard self.view !== view else { return }
        let old = self.view
        self.view = view
        lock.lock()
        rule.reset()
        let released = takeAll()
        frameLayer = view?.liveFrameLayer
        detailLayer = view?.detailFrameLayer
        imageSize = nil
        corners = nil
        epoch += 1
        changes += 1
        lock.unlock()
        if let old { Self.clear(old.liveFrameLayer); Self.clear(old.detailFrameLayer) }
        release(released)
        cancelExpiry()
    }

    /// Frames requested before this call are dropped: the photo, the Before view, the crop tool
    /// or a slider's Option view changed.
    func invalidate() {
        lock.lock()
        epoch += 1
        lock.unlock()
    }

    /// What a render requested now must carry to be shown.
    var currentEpoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// Whether a sharp render can come; see `canSharpen`. Set by `DevelopController`.
    @MainActor
    func setCanSharpen(_ on: Bool) {
        lock.lock()
        guard canSharpen != on else { return lock.unlock() }
        canSharpen = on
        lock.unlock()
        applyNeed()
    }

    /// The part of the photo in view and the pixels it takes to be sharp there, from the view.
    @MainActor
    func setNeed(_ need: DisplayNeed, pixels: CGSize) {
        lock.lock()
        viewNeed = need
        target = need.visible.width < 0.995 || need.visible.height < 0.995
            ? RegionTarget(visible: need.visible, pixels: pixels) : nil
        lock.unlock()
        applyNeed()
    }

    /// Where the photo is in the canvas layer and the shape whole-photo frames must have, after
    /// the view sized itself for an image.
    @MainActor
    func setGeometry(imageSize: CGSize?, corners: (CGPoint, CGPoint)?) {
        lock.lock()
        self.imageSize = imageSize
        self.corners = corners
        changes += 1
        lock.unlock()
        sync()
    }

    /// The image the view was handed (`ZoomScrollView.setImage`). The view applies it
    /// (`applyImage`) when it goes on screen, now or once its wait is over.
    @MainActor
    func offer(_ image: NSImage, tag: DisplayTag, pixelSize: CGSize?) {
        lock.lock()
        let decision = rule.offer(tag, now: CACurrentMediaTime())
        let released = apply(decision, tag: tag, content: .image(image, pixelSize: pixelSize))
        lock.unlock()
        release(released)
        sync()
        scheduleExpiry()
    }

    /// The view has no image (no photo, or it couldn't be opened).
    @MainActor
    func clear() {
        lock.lock()
        rule.reset()
        let released = takeAll()
        changes += 1
        lock.unlock()
        release(released)
        view?.applyImage(nil, pixelSize: nil)
        sync()
        cancelExpiry()
    }

    /// The next photo is waiting to be shown sharp; the view keeps the last one's zoom and spot
    /// until it is (`ZoomScrollView.applyPendingCenter`).
    var holdsNewPhoto: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = rule.pending else { return false }
        return pending.tag.photo > (rule.visible?.photo ?? .min)
    }

    // MARK: Any thread

    /// What a sharp visible-area render should make now, or nil when the image `wholeDensity`
    /// pixels across the photo is sharp enough for the view (at Fit, just past it) or no sharp
    /// render can come.
    func regionTarget(over wholeDensity: Double) -> RegionTarget? {
        lock.lock()
        defer { lock.unlock() }
        guard canSharpen, let target, viewNeed.density > wholeDensity / 0.95 else { return nil }
        return target
    }

    /// The photo's tag for a whole-photo image `pixelWidth` across, as the rule would rank it.
    func isSharp(_ tag: DisplayTag) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rule.isSharp(tag)
    }

    /// A rendered surface: a live frame of the whole photo (`region` nil) or a visible-area frame,
    /// of open `photo` and edit `revision`, requested at `epoch`. On screen on the calling thread
    /// when the rule says so; the surface goes back to `pool` whenever it isn't kept.
    func offer(surface: IOSurface, pool: DisplaySurfaces, photo: Int, revision: Int, region: CGRect?,
               epoch: Int) -> Outcome {
        lock.lock()
        let outcome: Outcome
        var released: [(IOSurface, DisplaySurfaces)] = []
        var mainSync = false
        let tag = DisplayTag(photo: photo, revision: revision, region: region ?? DisplayTag.whole,
                             pixelWidth: Double(surface.width))
        if epoch != self.epoch {
            outcome = .stale
        } else if frameLayer == nil {
            outcome = .noView
        } else if region == nil, !(imageSize.map { Self.fits(surface, $0) } ?? false) {
            outcome = .wrongShape
        } else {
            let decision = rule.offer(tag, now: CACurrentMediaTime())
            released = apply(decision, tag: tag, content: .surface(surface, pool))
            switch decision {
            case .show, .showOverHeld: outcome = .shown
            case .wait: outcome = .held
            case .drop: outcome = .notNeeded
            }
            // The base became an ordinary image (the one that waited), or a wait began: both
            // are the main thread's.
            if case .showOverHeld = decision { mainSync = true }
            if case .wait = decision { mainSync = true }
        }
        let kept: Bool
        switch outcome {
        case .shown, .held: kept = true
        default: kept = false
        }
        guard kept else {
            lock.unlock()
            pool.checkIn(surface)
            return outcome
        }
        let layers = snapshot()
        let mine = changes
        lock.unlock()
        if outcome == .shown {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            Self.set(layers)
            CATransaction.commit()
            // This thread has no run loop to commit for it.
            CATransaction.flush()
        }
        release(released)
        lock.lock()
        let changedMeanwhile = changes != mine
        lock.unlock()
        if changedMeanwhile || mainSync {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.sync(); self.scheduleExpiry() } }
        }
        return outcome
    }

    // MARK: Applying decisions (under the lock)

    /// Updates the contents for `decision` on `tag` (made of `content`). Returns the surfaces no
    /// longer kept, to give back once they are off the layers.
    private func apply(_ decision: SharpDisplay.Decision, tag: DisplayTag, content: Content) -> [(IOSurface, DisplaySurfaces)] {
        var released: [(IOSurface, DisplaySurfaces)] = []
        switch decision {
        case .show(.base, let clearsDetail):
            if let old = base?.surface { released.append(old) }
            base = content
            if clearsDetail, let old = detail {
                released.append(old)
                detail = nil
            }
        case .show(.detail, _):
            if let old = detail { released.append(old) }
            detail = content.surface
        case .showOverHeld:
            if let old = base?.surface { released.append(old) }
            base = held?.content
            held = nil
            if let old = detail { released.append(old) }
            detail = content.surface
        case .wait:
            if let old = held?.content.surface, old.0 !== content.surface?.0 { released.append(old) }
            held = (tag, content)
        case .drop:
            break
        }
        released += settle()
        changes += 1
        return released
    }

    /// Lets go of contents the rule no longer has: a waiting image it dropped or showed, a
    /// visible-area frame panned off.
    private func settle() -> [(IOSurface, DisplaySurfaces)] {
        var released: [(IOSurface, DisplaySurfaces)] = []
        if let held, rule.pending?.tag != held.tag {
            if let surface = held.content.surface, base?.surface?.0 !== surface.0 { released.append(surface) }
            self.held = nil
        }
        if rule.detail == nil, let old = detail {
            released.append(old)
            detail = nil
        }
        return released
    }

    private func takeAll() -> [(IOSurface, DisplaySurfaces)] {
        var released: [(IOSurface, DisplaySurfaces)] = []
        if let surface = base?.surface { released.append(surface) }
        if let surface = held?.content.surface { released.append(surface) }
        if let detail { released.append(detail) }
        base = nil
        held = nil
        detail = nil
        return released
    }

    private struct Layers {
        weak var frameLayer: CALayer?
        weak var detailLayer: CALayer?
        var frame: IOSurface?
        var detail: IOSurface?
        var detailRect: CGRect?
    }

    private func snapshot() -> Layers {
        var rect: CGRect?
        if detail != nil, let region = rule.detail?.region, let corners {
            let (a, b) = corners
            let x0 = a.x + region.minX * (b.x - a.x), x1 = a.x + region.maxX * (b.x - a.x)
            let y0 = a.y + region.minY * (b.y - a.y), y1 = a.y + region.maxY * (b.y - a.y)
            rect = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
        return Layers(frameLayer: frameLayer, detailLayer: detailLayer, frame: base?.surface?.0,
                      detail: rect == nil ? nil : detail?.0, detailRect: rect)
    }

    private static func set(_ layers: Layers) {
        if let frameLayer = layers.frameLayer {
            if let frame = layers.frame {
                if frameLayer.contents as AnyObject? !== frame { frameLayer.contents = frame }
                frameLayer.isHidden = false
            } else if !frameLayer.isHidden || frameLayer.contents != nil {
                frameLayer.contents = nil
                frameLayer.isHidden = true
            }
        }
        if let detailLayer = layers.detailLayer {
            if let detail = layers.detail, let rect = layers.detailRect {
                detailLayer.bounds = CGRect(origin: .zero, size: rect.size)
                detailLayer.position = CGPoint(x: rect.midX, y: rect.midY)
                if detailLayer.contents as AnyObject? !== detail { detailLayer.contents = detail }
                detailLayer.isHidden = false
            } else if !detailLayer.isHidden || detailLayer.contents != nil {
                detailLayer.contents = nil
                detailLayer.isHidden = true
            }
        }
    }

    private func release(_ surfaces: [(IOSurface, DisplaySurfaces)]) {
        for (surface, pool) in surfaces { pool.checkIn(surface) }
    }

    // MARK: Main-thread application

    /// Puts the layers in line with the state: the base image on the canvas (through the view,
    /// which sizes itself for it), the live frame and the visible-area frame over it.
    @MainActor
    private func sync() {
        lock.lock()
        let image = base?.image
        lock.unlock()
        if let image, let view, view.appliedImage !== image.0 {
            // Sizes the view for it, which can come back here with its geometry.
            view.applyImage(image.0, pixelSize: image.1)
        }
        lock.lock()
        let layers = snapshot()
        lock.unlock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.set(layers)
        CATransaction.commit()
    }

    @MainActor
    private func applyNeed() {
        lock.lock()
        let need = canSharpen ? viewNeed : DisplayNeed(visible: viewNeed.visible, density: 0)
        _ = rule.setNeed(need)
        var released = settle()
        // A waiting image that is sharp enough for the view now (back to Fit) shows at once.
        if let pending = rule.pending, rule.isSharp(pending.tag) {
            let decision = rule.expire(now: pending.deadline)
            if let held { released += apply(decision, tag: held.tag, content: held.content) }
        }
        changes += 1
        lock.unlock()
        release(released)
        sync()
        scheduleExpiry()
    }

    @MainActor
    private func scheduleExpiry() {
        lock.lock()
        let deadline = rule.pending?.deadline
        lock.unlock()
        guard let deadline else { return cancelExpiry() }
        if let expiry, abs(expiry.deadline - deadline) < 0.0005 { return }
        cancelExpiry()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.expire() }
        }
        expiry = (deadline, item)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime()), execute: item)
    }

    @MainActor
    private func cancelExpiry() {
        expiry?.item.cancel()
        expiry = nil
    }

    @MainActor
    private func expire() {
        expiry = nil
        lock.lock()
        var released: [(IOSurface, DisplaySurfaces)] = []
        if let held {
            let decision = rule.expire(now: CACurrentMediaTime())
            released = apply(decision, tag: held.tag, content: held.content)
            // It was the waiting one; showing it doesn't give it back.
            released.removeAll { $0.0 === held.content.surface?.0 && base?.surface?.0 === $0.0 }
        }
        lock.unlock()
        release(released)
        sync()
        scheduleExpiry()
    }

    // MARK: Helpers

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
