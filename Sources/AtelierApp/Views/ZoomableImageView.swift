import AppKit
import SwiftUI

/// Zoom for loupe and develop. 100% shows one pixel of the full-size photo per screen pixel.
enum ZoomLevel: Hashable {
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
    @Published var level: ZoomLevel = .fit
    @Published var report = ZoomReport()
    /// Where the next photo should be centered (0...1 across and down the photo), for the
    /// settings that bring back a zoomed photo's position. The photo view takes it.
    var pendingCenter: CGPoint?
    /// The visible center of the photo shown now, from the photo view.
    var currentCenter: (@MainActor () -> CGPoint?)?
    /// Centers the photo view on a point (0...1 across and down the photo), zooming in first
    /// when the whole photo is in view. Set by the photo view; the Navigator calls it.
    var focus: (@MainActor (CGPoint) -> Void)?
    /// The part of the photo in view, for the Navigator's rectangle.
    let viewport = ZoomViewport()
}

/// The part of the photo the photo view shows. Its own object so that scrolling redraws only
/// the Navigator's rectangle, not the photo view or the zoom bar.
@MainActor
final class ZoomViewport: ObservableObject {
    /// 0...1 across and down the photo; nil when the whole photo is in view or no photo view
    /// is showing.
    @Published private(set) var visible: CGRect?
    private var owner: ObjectIdentifier?

    func update(_ rect: CGRect?, from source: AnyObject) {
        owner = ObjectIdentifier(source)
        if let rect, let visible, abs(rect.minX - visible.minX) < 0.0005, abs(rect.minY - visible.minY) < 0.0005,
           abs(rect.width - visible.width) < 0.0005, abs(rect.height - visible.height) < 0.0005 { return }
        if rect != visible { visible = rect }
    }

    /// Clears the rectangle when `source` was the last photo view to report, so a view that
    /// goes away doesn't wipe out the one that replaced it.
    func clear(from source: AnyObject) {
        guard owner == ObjectIdentifier(source) else { return }
        owner = nil
        if visible != nil { visible = nil }
    }
}

/// A photo that zooms with pinch, the zoom bar, ⌘/⌥-scroll or a click, and pans by dragging.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    /// Size of the full-resolution photo; the displayed image may be a smaller proxy.
    let pixelSize: CGSize?
    @ObservedObject var zoom: ZoomState
    var dimmed = false
    var onReport: (ZoomReport) -> Void
    var menu: () -> NSMenu?

    func makeNSView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.menuProvider = menu
        view.onReport = onReport
        let zoom = self.zoom
        view.onZoomChange = { level in
            if zoom.level != level { zoom.level = level }
        }
        zoom.currentCenter = { [weak view] in view?.relativeCenter }
        zoom.focus = { [weak view] center in view?.focus(on: center) }
        view.viewport = zoom.viewport
        // Only a new photo takes the position: ZoomState changes reach this view before the
        // window passes it the next photo, and the photo still shown must not use it.
        if let center = zoom.pendingCenter, let image, image !== view.shownImage {
            view.pendingCenter = center
            zoom.pendingCenter = nil
        }
        view.setImage(image, pixelSize: pixelSize)
        view.setDimmed(dimmed)
        view.apply(zoom.level)
        view.applyPendingCenter()
    }
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
    /// Told what part of the photo is in view, for the Navigator.
    weak var viewport: ZoomViewport? {
        didSet { if viewport !== oldValue { reportVisible() } }
    }

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
            let next = ZoomLevel.percent(LibraryModel.clickZoomPercent)
            applyLevel(next, anchor: nil)
            onZoomChange?(next)
        }
        scroll(toRelative: center)
    }

    @objc private func visibleDidChange() {
        reportVisible()
    }

    /// Tells the Navigator what part of the photo is in view, after the current layout pass.
    private func reportVisible() {
        guard let viewport else { return }
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

    private func scroll(toRelative center: CGPoint) {
        let size = contentView.bounds.size
        let origin = NSPoint(x: center.x * documentSize.width - size.width / 2,
                             y: center.y * documentSize.height - size.height / 2)
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: size)).origin)
        reflectScrolledClipView(contentView)
        report()
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
        canvas.window?.invalidateCursorRects(for: canvas)
        report()
    }

    func toggleZoom(at point: NSPoint) {
        let next: ZoomLevel = lastReport.isZoomedPastFit ? .fit : .percent(LibraryModel.clickZoomPercent)
        applyLevel(next, anchor: point)
        onZoomChange?(next)
    }

    var canPan: Bool { lastReport.isZoomedPastFit || level == .fill }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if level == .fit || level == .fill {
            magnification = magnification(for: level)
        }
        applyPendingCenter()
        report()
        reportVisible()
    }

    @objc private func didEndMagnify() {
        level = .percent(Double(magnification * 100))
        onZoomChange?(level)
        report()
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

/// Draws the photo with a GPU-scaled layer; handles click-to-zoom and drag-to-pan.
final class ZoomCanvasView: NSView {
    weak var scrollView: ZoomScrollView?
    private var dragStart: NSPoint?
    private var dragged = false
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

    override func resetCursorRects() {
        if scrollView?.canPan == true { addCursorRect(visibleRect, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scrollView, scrollView.canPan else { return }
        let location = event.locationInWindow
        let delta = NSPoint(x: location.x - start.x, y: location.y - start.y)
        if !dragged, abs(delta.x) + abs(delta.y) < 3 { return }
        if !dragged { NSCursor.closedHand.push() }
        dragged = true
        scrollView.pan(by: delta)
        dragStart = location
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            NSCursor.pop()
        } else if event.clickCount == 1 {
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
