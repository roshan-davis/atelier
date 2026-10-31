import AppKit
import AtelierCore
import SwiftUI

/// Zoom for loupe and develop. 100% shows one pixel of the full-size photo per screen pixel.
enum ZoomLevel: Hashable {
    static var clickZoomPercent: Double {
        let value = UserDefaults.standard.double(forKey: "zoom.clickPercent")
        return value > 0 ? value : 100
    }

    case fit, fill
    case percent(Double)

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .percent(let value): return "\(Int(value.rounded()))%"
        }
    }

    static let presets: [ZoomLevel] = [.fit, .fill, .percent(100), .percent(200)]
}

/// What the zoomed view currently shows, reported back for the zoom bar and full-res loading.
struct ZoomReport: Equatable {
    var percent: Double = 0
    var fitPercent: Double = 0
    var isZoomedPastFit: Bool { percent > fitPercent * 1.01 }
}

/// The loupe and develop zoom, and what it currently shows. Kept out of `LibraryModel` so a
/// zoom change redraws only the photo and the zoom bar, not the whole window.
@MainActor
final class ZoomState: ObservableObject {
    @Published var level: ZoomLevel = .fit {
        didSet { if level == .fit { viewport.forgetCenter() } }
    }
    @Published var report = ZoomReport()
    /// Where the next photo should be centered (0...1 across and down the photo), for the
    /// settings that bring back a zoomed photo's position. The photo view takes it.
    var pendingCenter: CGPoint?
    /// Where the photo view on screen now should be centered (0...1 across and down the
    /// photo), taken by the next view to update whatever photo it shows. For coming back from
    /// the compare views, where the photo view is new but the photo is the same.
    var restoreCenter: CGPoint?
    /// The visible center of the photo shown now, from the photo view.
    var currentCenter: (@MainActor () -> CGPoint?)?
    /// Centers the photo view on a point (0...1 across and down the photo), zooming in first
    /// when the whole photo is in view. Set by the photo view; the Navigator calls it.
    var focus: (@MainActor (CGPoint) -> Void)?
    /// The part of the photo in view, for the Navigator's rectangle.
    let viewport = ZoomViewport()
    /// The photo views using this zoom. Those on screen together (the before and after compare
    /// panes) stay on the same spot at the same zoom.
    let views = NSHashTable<ZoomScrollView>.weakObjects()

    /// Puts the next photo on the photo view now, before SwiftUI's update for it, which redraws
    /// the whole window and can take a few hundred ms (measured 190 to 320 ms in a Debug build,
    /// AT-019). Only with one plain photo view on screen; compare panes and tools wait for the
    /// update. The update then passes the same image, which changes nothing.
    func showNow(_ image: NSImage, pixelSize: CGSize?) {
        let onScreen = views.allObjects.filter { $0.window != nil }
        guard onScreen.count == 1, let view = onScreen.first, view.visibleWidth == nil, !view.hasOverlay else { return }
        if let center = pendingCenter {
            view.pendingCenter = center
            pendingCenter = nil
        }
        view.setImage(image, pixelSize: pixelSize)
        view.apply(level)
        view.applyPendingCenter()
        // Draw it now rather than when the window's update ends.
        CATransaction.flush()
    }
}

/// The part of the photo the photo view shows. Its own object so that scrolling redraws only
/// the Navigator's rectangle, not the photo view or the zoom bar.
@MainActor
final class ZoomViewport: ObservableObject {
    /// 0...1 across and down the photo; nil when the whole photo is in view or no photo view
    /// is showing.
    @Published private(set) var visible: CGRect?
    /// The spot of the photo (0...1 across and down it) the view is zoomed in on; nil at Fit.
    /// The one place it lives: every photo view (Develop, Masking, the loupe) writes it as it
    /// pans and starts from it when it appears, so switching to any mode and back keeps the
    /// spot without each mode saving it. A crop change moves it with the photo (`recrop`).
    private(set) var center: CGPoint?
    private var owner: ObjectIdentifier?

    func update(_ rect: CGRect?, from source: AnyObject) {
        owner = ObjectIdentifier(source)
        // All of the photo in view says nothing about where to zoom in; keep the spot.
        if let rect { center = CGPoint(x: rect.midX, y: rect.midY) }
        if let rect, let visible, abs(rect.minX - visible.minX) < 0.0005, abs(rect.minY - visible.minY) < 0.0005,
           abs(rect.width - visible.width) < 0.0005, abs(rect.height - visible.height) < 0.0005 { return }
        if rect != visible { visible = rect }
    }

    func forgetCenter() { center = nil }

    /// Moves the spot with the photo when its crop changes from `old` to `new`, so the same
    /// part of the photo stays in view. `sourceSize` is the upright, uncropped photo's size.
    func recrop(from old: DevelopSettings.Crop, to new: DevelopSettings.Crop, sourceSize: CGSize) {
        guard let center, old != new else { return }
        let oldSize = old.outputSize(sourceSize), newSize = new.outputSize(sourceSize)
        guard oldSize.width > 0, oldSize.height > 0, newSize.width > 0, newSize.height > 0 else { return }
        let source = old.sourcePoint(fromOutput: CGPoint(x: center.x * oldSize.width, y: center.y * oldSize.height),
                                     sourceSize: sourceSize)
        let point = new.outputPoint(fromSource: source, sourceSize: sourceSize)
        self.center = CGPoint(x: min(1, max(0, point.x / newSize.width)), y: min(1, max(0, point.y / newSize.height)))
    }

    /// Clears the rectangle when `source` was the last photo view to report, so a view that
    /// goes away doesn't wipe out the one that replaced it.
    func clear(from source: AnyObject) {
        guard owner == ObjectIdentifier(source) else { return }
        owner = nil
        if visible != nil { visible = nil }
    }
}

/// A drag with the Targeted Adjustment Tool: where it began (0...1 across and down the photo),
/// how far it has moved up since (points; negative is down), and its end.
enum PhotoDrag {
    case began(CGPoint)
    case moved(Double)
    case ended
}

/// A photo that zooms with pinch, the zoom bar, ⌘/⌥-scroll or a double-click, and pans by dragging.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    /// Size of the full-resolution photo; the displayed image may be a smaller proxy.
    let pixelSize: CGSize?
    @ObservedObject var zoom: ZoomState
    var dimmed = false
    /// Shows only the left part of the view, 0...1 across it (the slider compare's before
    /// side); nil shows all of it.
    var visibleWidth: CGFloat? = nil
    var onReport: (ZoomReport) -> Void
    var menu: () -> NSMenu?
    /// Set while a picker is out (the Fringe Color Selector): a click reports the point
    /// (0...1 across and down the photo) instead of zooming; dragging still pans.
    var onPick: ((CGPoint) -> Void)? = nil
    /// Set while the Targeted Adjustment Tool is out: dragging up or down on the photo reports
    /// the drag instead of panning.
    var onPickDrag: ((PhotoDrag) -> Void)? = nil
    /// A tool drawn over the photo (Masking), given where the photo is as it zooms and scrolls.
    /// It stays the same size on screen; scroll and pinch on it still zoom and pan the photo.
    var overlay: ((PhotoFrame) -> AnyView)? = nil

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        // A new photo view (back from another mode) starts on the spot the last one showed.
        view.pendingCenter = zoom.viewport.center
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.menuProvider = menu
        view.onReport = onReport
        view.onPick = onPick
        view.onPickDrag = onPickDrag
        let zoom = self.zoom
        view.onZoomChange = { level in
            if zoom.level != level { zoom.level = level }
        }
        zoom.currentCenter = { [weak view] in view?.relativeCenter }
        zoom.focus = { [weak view] center in view?.focus(on: center) }
        view.viewport = zoom.viewport
        view.zoomState = zoom
        zoom.views.add(view)
        view.visibleWidth = visibleWidth
        // Only a new photo takes the position: ZoomState changes reach this view before the
        // window passes it the next photo, and the photo still shown must not use it.
        if let center = zoom.pendingCenter, let image, image !== view.shownImage {
            view.pendingCenter = center
            zoom.pendingCenter = nil
        }
        if let center = zoom.restoreCenter {
            view.pendingCenter = center
            zoom.restoreCenter = nil
        }
        view.isUpdating = true
        view.setImage(image, pixelSize: pixelSize)
        view.setDimmed(dimmed)
        view.apply(zoom.level)
        view.applyPendingCenter()
        view.setOverlay(overlay?(view.photoFrame))
        view.isUpdating = false
        // Published after this update, not during it.
        DispatchQueue.main.async { [weak view] in MainActor.assumeIsolated { view?.updatePhotoFrame() } }
    }
}

/// Where the photo sits in a photo view, in the view's own top-left coordinates, for a tool
/// drawn over it. Kept by the photo view as it zooms and scrolls.
@MainActor
final class PhotoFrame: ObservableObject {
    @Published fileprivate(set) var rect = CGRect.zero
    /// Zoomed in far enough that dragging moves around the photo.
    fileprivate(set) var canPan = false
    /// Moves the photo with a drag of this many points (y down).
    fileprivate(set) var pan: ((CGSize) -> Void)?
}

final class ZoomScrollView: NSScrollView {
    private let canvas = ZoomCanvasView()
    private(set) var level: ZoomLevel = .fit
    private var documentSize = CGSize.zero
    private var lastReport = ZoomReport()
    private let padding: CGFloat = 16

    /// A position to center on (0...1 across and down the photo) once the photo and the view
    /// have their sizes.
    var pendingCenter: CGPoint?
    var onZoomChange: ((ZoomLevel) -> Void)?
    var onReport: ((ZoomReport) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// Takes clicks instead of zooming; see `ZoomableImageView.onPick`.
    var onPick: ((CGPoint) -> Void)? {
        didSet {
            if (onPick == nil) != (oldValue == nil) { Cursors.shared.refresh() }
        }
    }
    /// Takes drags instead of panning; see `ZoomableImageView.onPickDrag`.
    var onPickDrag: ((PhotoDrag) -> Void)? {
        didSet {
            if (onPickDrag == nil) != (oldValue == nil) { Cursors.shared.refresh() }
        }
    }
    /// Told what part of the photo is in view, for the Navigator.
    weak var viewport: ZoomViewport? {
        didSet { if viewport !== oldValue { reportVisible() } }
    }
    weak var zoomState: ZoomState?
    /// Shows only the left part of the view, 0...1 across it; nil shows all of it.
    var visibleWidth: CGFloat? {
        didSet { if visibleWidth != oldValue { updateMask() } }
    }
    /// Set while following another view, so the move isn't sent back to it.
    private var following = false
    /// Set while SwiftUI updates this view, when the photo frame mustn't be published.
    var isUpdating = false
    let photoFrame = PhotoFrame()
    private var overlayHost: OverlayHostingView?

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        documentView = canvas
        canvas.scrollView = self
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 16
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        contentView.drawsBackground = false
        NotificationCenter.default.addObserver(self, selector: #selector(didEndMagnify),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleDidChange),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
        photoFrame.pan = { [weak self] delta in self?.pan(by: NSPoint(x: delta.width, y: -delta.height)) }
    }

    // MARK: Overlay

    /// Shows `view` over the photo, or removes the overlay. Scroll and pinch on the overlay are
    /// handed to this view, so the photo zooms and pans under any tool the same way.
    func setOverlay(_ view: AnyView?) {
        guard let view else {
            overlayHost?.removeFromSuperview()
            overlayHost = nil
            Cursors.shared.refresh()
            return
        }
        if let overlayHost {
            overlayHost.rootView = view
        } else {
            let host = OverlayHostingView(rootView: view)
            host.scrollView = self
            // Cover the whole view, not the overlay's own ideal size, or clicks miss it.
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host, positioned: .above, relativeTo: nil)
            overlayHost = host
            Cursors.shared.refresh()
        }
    }

    /// A tool is drawn over the photo; it decides the cursor.
    var hasOverlay: Bool { overlayHost != nil }

    override func tile() {
        super.tile()
        overlayHost?.frame = bounds
    }

    /// Tells the overlay where the photo is now.
    func updatePhotoFrame() {
        guard let overlayHost, !isUpdating else { return }
        let rect = documentSize.width > 0 ? overlayHost.convert(canvas.bounds, from: canvas) : .zero
        photoFrame.canPan = canPan
        if photoFrame.rect != rect { photoFrame.rect = rect }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Content

    /// The image last passed to `setImage`.
    private(set) var shownImage: NSImage?

    func setImage(_ image: NSImage?, pixelSize: CGSize?) {
        shownImage = image
        canvas.setImage(image)
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        // Keep the displayed image's aspect, at the full-size photo's long edge.
        var pixels = image.size
        if let pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            let factor = max(pixelSize.width, pixelSize.height) / max(image.size.width, image.size.height)
            pixels = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        }
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: pixels.width / backing, height: pixels.height / backing)
        guard abs(size.width - documentSize.width) > 0.5 || abs(size.height - documentSize.height) > 0.5 else { return }
        // Keep the same spot of the photo in the middle when its size changes (the proxy
        // replacing the cached preview, or the next photo at a kept zoom).
        let center = relativeCenter
        documentSize = size
        canvas.frame = CGRect(origin: .zero, size: size)
        applyLevel(level, anchor: nil)
        if let center { scroll(toRelative: center) }
    }

    /// The middle of what's visible, 0...1 across and down the photo; nil before it has a size.
    var relativeCenter: CGPoint? {
        guard documentSize.width > 0, documentSize.height > 0 else { return nil }
        let visible = contentView.bounds
        return CGPoint(x: min(1, max(0, visible.midX / documentSize.width)),
                       y: min(1, max(0, visible.midY / documentSize.height)))
    }

    /// Scrolls so `center` (0...1 across and down the photo) is in the middle, for the
    /// Navigator. From Fit it first zooms to the click zoom, as Lightroom's Navigator does.
    func focus(on center: CGPoint) {
        guard documentSize.width > 0, documentSize.height > 0 else { return }
        if !canPan {
            let next = ZoomLevel.percent(ZoomLevel.clickZoomPercent)
            applyLevel(next, anchor: nil)
            onZoomChange?(next)
        }
        scroll(toRelative: center)
    }

    @objc private func visibleDidChange() {
        reportVisible()
        leadPeers()
        updatePhotoFrame()
    }

    // MARK: Compare panes

    /// The other photo views on screen with the same zoom, ready to show a photo.
    private var peers: [ZoomScrollView] {
        guard let zoomState else { return [] }
        return zoomState.views.allObjects.filter {
            $0 !== self && $0.window != nil && $0.documentSize.width > 0 && $0.bounds.width > 0
        }
    }

    /// Moves the other compare panes to the same zoom and spot as this one.
    private func leadPeers() {
        guard !following, let center = relativeCenter else { return }
        for peer in peers { peer.follow(magnification: magnification, level: level, center: center) }
    }

    /// Doesn't report: the leading pane reports the zoom, and a report from every follow
    /// during a pinch would publish to the whole window on every frame.
    private func follow(magnification target: CGFloat, level newLevel: ZoomLevel, center: CGPoint) {
        following = true
        defer { following = false }
        level = newLevel
        if abs(magnification - target) > 0.0001 { magnification = target }
        scroll(toRelative: center, reporting: false)
        // Still know the zoom here, so this pane can be dragged.
        lastReport = ZoomReport(percent: Double(magnification * 100), fitPercent: Double(fitMagnification * 100))
        Cursors.shared.refresh()
    }

    /// A pane that appears or resizes after its partner takes the partner's zoom and spot.
    private func joinPeers() {
        guard pendingCenter == nil, documentSize.width > 0, bounds.width > 0,
              let peer = peers.first, let center = peer.relativeCenter else { return }
        follow(magnification: peer.magnification, level: peer.level, center: center)
    }

    private func updateMask() {
        guard let visibleWidth else {
            layer?.mask = nil
            return
        }
        wantsLayer = true
        let mask = layer?.mask ?? CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: bounds.width * min(1, max(0, visibleWidth)), height: bounds.height)
        CATransaction.commit()
        layer?.mask = mask
    }

    /// Clicks right of the visible part go to the view underneath. With a tool over the photo,
    /// every click and drag goes to the tool, never to panning the photo underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let superview {
            let local = convert(point, from: superview)
            if let visibleWidth, local.x > bounds.width * visibleWidth { return nil }
            if let overlayHost, bounds.contains(local) { return overlayHost.hitTest(local) ?? overlayHost }
        }
        return super.hitTest(point)
    }

    /// Tells the Navigator what part of the photo is in view, after the current layout pass.
    private func reportVisible() {
        // Until the view has taken its spot, what it shows isn't where it is going.
        guard let viewport, pendingCenter == nil else { return }
        var visible: CGRect?
        if documentSize.width > 0, documentSize.height > 0 {
            let shown = contentView.bounds.intersection(CGRect(origin: .zero, size: documentSize))
            if !shown.isNull {
                let rect = CGRect(x: shown.minX / documentSize.width, y: shown.minY / documentSize.height,
                                  width: shown.width / documentSize.width, height: shown.height / documentSize.height)
                if rect.width < 0.995 || rect.height < 0.995 { visible = rect }
            }
        }
        DispatchQueue.main.async { [weak self, weak viewport] in
            MainActor.assumeIsolated {
                guard let self else { return }
                viewport?.update(visible, from: self)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return reportVisible() }
        guard let viewport else { return }
        DispatchQueue.main.async { [weak viewport] in
            MainActor.assumeIsolated { viewport?.clear(from: self) }
        }
    }

    func applyPendingCenter() {
        guard let center = pendingCenter, documentSize.width > 0, bounds.width > 0, bounds.height > 0 else { return }
        pendingCenter = nil
        scroll(toRelative: center)
    }

    private func scroll(toRelative center: CGPoint, reporting: Bool = true) {
        let size = contentView.bounds.size
        let origin = NSPoint(x: center.x * documentSize.width - size.width / 2,
                             y: center.y * documentSize.height - size.height / 2)
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: size)).origin)
        reflectScrolledClipView(contentView)
        if reporting { report() }
    }

    func setDimmed(_ dimmed: Bool) {
        canvas.alphaValue = dimmed ? 0.4 : 1
    }

    // MARK: Zoom

    func apply(_ newLevel: ZoomLevel) {
        guard newLevel != level else { return }
        applyLevel(newLevel, anchor: nil)
    }

    private var fitMagnification: CGFloat {
        guard documentSize.width > 0, documentSize.height > 0 else { return 1 }
        let width = max(1, bounds.width - padding * 2), height = max(1, bounds.height - padding * 2)
        return min(width / documentSize.width, height / documentSize.height)
    }

    private var fillMagnification: CGFloat {
        guard documentSize.width > 0, documentSize.height > 0 else { return 1 }
        return max(bounds.width / documentSize.width, bounds.height / documentSize.height)
    }

    private func magnification(for level: ZoomLevel) -> CGFloat {
        switch level {
        case .fit: return fitMagnification
        case .fill: return fillMagnification
        case .percent(let value): return CGFloat(value / 100)
        }
    }

    /// Zooms around `anchor` (document coordinates), or around the visible center.
    private func applyLevel(_ newLevel: ZoomLevel, anchor: NSPoint?) {
        level = newLevel
        let target = min(maxMagnification, max(minMagnification, magnification(for: newLevel)))
        let visible = contentView.bounds
        let center = anchor ?? NSPoint(x: visible.midX, y: visible.midY)
        setMagnification(target, centeredAt: center)
        Cursors.shared.refresh()
        report()
    }

    func toggleZoom(at point: NSPoint) {
        let next: ZoomLevel = lastReport.isZoomedPastFit ? .fit : .percent(ZoomLevel.clickZoomPercent)
        applyLevel(next, anchor: point)
        onZoomChange?(next)
    }

    /// Part of the photo is out of view, so a drag moves it. Measured, not taken from the zoom
    /// level: just past Fit, or at Fill with the view's shape, the whole photo can still fit.
    var canPan: Bool {
        guard documentSize.width > 0, documentSize.height > 0 else { return false }
        let visible = contentView.bounds.size
        // In screen points, so a sliver under a point doesn't count.
        return (documentSize.width - visible.width) * magnification > 1
            || (documentSize.height - visible.height) * magnification > 1
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if level == .fit || level == .fill {
            magnification = magnification(for: level)
        }
        applyPendingCenter()
        joinPeers()
        updateMask()
        report()
        reportVisible()
        updatePhotoFrame()
        // A bigger window can leave nothing to pan, a smaller one something.
        Cursors.shared.refresh()
    }

    @objc private func didEndMagnify() {
        level = .percent(Double(magnification * 100))
        onZoomChange?(level)
        report()
        updatePhotoFrame()
        Cursors.shared.refresh()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !event.modifierFlags.intersection([.command, .option]).isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
        let point = canvas.convert(event.locationInWindow, from: nil)
        let newLevel = ZoomLevel.percent(Double(min(maxMagnification, max(minMagnification, magnification * factor)) * 100))
        applyLevel(newLevel, anchor: point)
        onZoomChange?(newLevel)
    }

    private func report() {
        let report = ZoomReport(percent: Double(magnification * 100), fitPercent: Double(fitMagnification * 100))
        guard report != lastReport else { return }
        lastReport = report
        let onReport = self.onReport
        // Reports can arrive during SwiftUI layout; publish afterwards.
        DispatchQueue.main.async { onReport?(report) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    // MARK: Panning

    func pan(by delta: NSPoint) {
        var origin = contentView.bounds.origin
        origin.x -= delta.x / magnification
        origin.y += delta.y / magnification
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }
}

/// A tool's SwiftUI overlay over the photo. It takes clicks and drags; scrolling and pinching
/// go to the photo view underneath.
final class OverlayHostingView: NSHostingView<AnyView> {
    weak var scrollView: ZoomScrollView?

    override func scrollWheel(with event: NSEvent) {
        if let scrollView { scrollView.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if let scrollView { scrollView.magnify(with: event) } else { super.magnify(with: event) }
    }
}

/// Draws the photo with a GPU-scaled layer; handles click-to-zoom and drag-to-pan.
final class ZoomCanvasView: NSView {
    weak var scrollView: ZoomScrollView?
    private var dragStart: NSPoint?
    private var dragged = false
    /// Where a Targeted Adjustment drag began, in window coordinates.
    private var pressStart: NSPoint?
    private var currentImage: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func setImage(_ image: NSImage?) {
        guard image !== currentImage else { return }
        currentImage = image
        layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Cursor

    private var tracking: NSTrackingArea?

    /// A picker's eyedropper, a hand when a drag moves the photo, else the arrow. No magnifier:
    /// zoom is a double-click, and a magnifier says a single click zooms (Rosh, Oct 30, 2026; the
    /// hint under the photo says how to zoom). Under a tool (Masking) the tool decides.
    private var cursorShape: CursorShape? {
        guard let scrollView, !scrollView.hasOverlay else { return nil }
        if scrollView.onPickDrag != nil { return .rowResize }
        if scrollView.onPick != nil { return .eyedropper }
        return scrollView.canPan ? .grab : .arrow
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                         .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func claimCursor() {
        Cursors.shared.hover(self, layer: .photo, window: window) { [weak self] in self?.cursorShape }
    }

    override func mouseEntered(with event: NSEvent) { claimCursor() }
    override func mouseMoved(with event: NSEvent) { claimCursor() }
    override func cursorUpdate(with event: NSEvent) { claimCursor() }
    override func mouseExited(with event: NSEvent) { Cursors.shared.leave(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { Cursors.shared.remove(self) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragged = false
        if let onPickDrag = scrollView?.onPickDrag {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return }
            pressStart = event.locationInWindow
            Cursors.shared.press(self, shape: .rowResize, window: window)
            onPickDrag(.began(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let onPickDrag = scrollView?.onPickDrag {
            guard let pressStart else { return }
            // Up is more, in points on screen.
            onPickDrag(.moved(Double(event.locationInWindow.y - pressStart.y)))
            return
        }
        guard let start = dragStart, let scrollView, scrollView.canPan else { return }
        let location = event.locationInWindow
        let delta = NSPoint(x: location.x - start.x, y: location.y - start.y)
        if !dragged, abs(delta.x) + abs(delta.y) < 3 { return }
        if !dragged { Cursors.shared.press(self, shape: .grabbing, window: window) }
        dragged = true
        scrollView.pan(by: delta)
        dragStart = location
    }

    override func mouseUp(with event: NSEvent) {
        if pressStart != nil {
            pressStart = nil
            Cursors.shared.release(self)
            scrollView?.onPickDrag?(.ended)
            dragStart = nil
            return
        }
        if dragged {
            Cursors.shared.release(self)
        } else if let onPick = scrollView?.onPick {
            let point = convert(event.locationInWindow, from: nil)
            if bounds.width > 0, bounds.height > 0, bounds.contains(point) {
                onPick(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
            }
        } else if event.clickCount == 2 {
            // Double-click, not a single click, so a stray click never resets the zoom (Rosh, Oct 29, 2026).
            scrollView?.toggleZoom(at: convert(event.locationInWindow, from: nil))
        }
        dragStart = nil
        dragged = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        scrollView?.menuProvider?() ?? super.menu(for: event)
    }
}

/// Keeps the photo centered when it is smaller than the view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Fit, Fill, 100%, 200% and the current zoom, under the photo.
struct ZoomControls: View {
    @ObservedObject var zoom: ZoomState
    /// A single menu instead of the segmented buttons, for narrow columns.
    var compact = false

    private var report: ZoomReport { zoom.report }

    private var percentText: String {
        report.percent > 0 ? "\(Int(report.percent.rounded()))%" : "Zoom"
    }

    var body: some View {
        if compact {
            Menu(percentText) {
                ForEach(ZoomLevel.presets, id: \.self) { level in
                    Button(level.label) { zoom.level = level }
                }
            }
            .fixedSize()
            .help("Zoom (Z toggles Fit and 100%; pinch, or hold ⌥ and scroll)")
        } else {
            HStack(spacing: 8) {
                Picker("Zoom", selection: $zoom.level) {
                    ForEach(ZoomLevel.presets, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Zoom (Z toggles Fit and 100%; pinch, or hold ⌥ and scroll)")
                Text(report.percent > 0 ? percentText : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}
