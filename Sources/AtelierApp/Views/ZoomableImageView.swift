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

/// A photo that zooms with pinch, the zoom bar, ⌘/⌥-scroll or a click, and pans by dragging.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    /// Size of the full-resolution photo; the displayed image may be a smaller proxy.
    let pixelSize: CGSize?
    @Binding var zoom: ZoomLevel
    var dimmed = false
    var onReport: (ZoomReport) -> Void
    var menu: () -> NSMenu?

    func makeNSView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.menuProvider = menu
        view.onReport = onReport
        view.onZoomChange = { level in
            if zoom != level { zoom = level }
        }
        view.setImage(image, pixelSize: pixelSize)
        view.setDimmed(dimmed)
        view.apply(zoom)
    }
}

final class ZoomScrollView: NSScrollView {
    private let canvas = ZoomCanvasView()
    private(set) var level: ZoomLevel = .fit
    private var documentSize = CGSize.zero
    private var lastReport = ZoomReport()
    private let padding: CGFloat = 16
    /// Set while a pinch or ⌥/⌘-scroll zoom is under way. The photo is only scaled on the GPU
    /// then: SwiftUI hears the new zoom, and a sharper image is swapped in, once it settles.
    private var isLiveZooming = false
    private var pendingImage: (image: NSImage?, pixelSize: CGSize?)?
    private var scrollZoomEnd: DispatchWorkItem?

    var onZoomChange: ((ZoomLevel) -> Void)?
    var onReport: ((ZoomReport) -> Void)?
    var menuProvider: (() -> NSMenu?)?

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
        NotificationCenter.default.addObserver(self, selector: #selector(willStartMagnify),
                                               name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(didEndMagnify),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Content

    func setImage(_ image: NSImage?, pixelSize: CGSize?) {
        // Swapping a full-resolution image in mid-gesture stalls a frame; wait until it ends.
        if isLiveZooming {
            pendingImage = (image, pixelSize)
            return
        }
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
        // The proxy and the full-resolution render round to slightly different aspects; treat
        // them as the same photo so the swap doesn't re-zoom.
        let tolerance = max(0.5, max(documentSize.width, documentSize.height) * 0.005)
        guard abs(size.width - documentSize.width) > tolerance || abs(size.height - documentSize.height) > tolerance else { return }
        documentSize = size
        canvas.frame = CGRect(origin: .zero, size: size)
        applyLevel(level, anchor: nil)
    }

    func setDimmed(_ dimmed: Bool) {
        canvas.alphaValue = dimmed ? 0.4 : 1
    }

    // MARK: Zoom

    func apply(_ newLevel: ZoomLevel) {
        // SwiftUI's zoom is behind during a gesture; it catches up when the gesture ends.
        guard !isLiveZooming, newLevel != level else { return }
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
        guard !isLiveZooming else { return }
        if level == .fit || level == .fill {
            magnification = magnification(for: level)
        }
        report()
    }

    // MARK: Live zoom

    @objc private func willStartMagnify() {
        scrollZoomEnd?.cancel()
        isLiveZooming = true
    }

    @objc private func didEndMagnify() {
        // Pinched out past fit: spring back, as in Preview and Lightroom.
        if magnification < fitMagnification * 0.999 {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                animator().magnification = fitMagnification
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.endLiveZoom() }
            })
        } else {
            endLiveZoom()
        }
    }

    /// Hands the settled zoom to SwiftUI, reports it, and shows any image that arrived meanwhile.
    private func endLiveZoom() {
        scrollZoomEnd?.cancel()
        scrollZoomEnd = nil
        isLiveZooming = false
        level = magnification <= fitMagnification * 1.001 ? .fit : .percent(Double(magnification * 100))
        if let pending = pendingImage {
            pendingImage = nil
            setImage(pending.image, pixelSize: pending.pixelSize)
        }
        canvas.window?.invalidateCursorRects(for: canvas)
        onZoomChange?(level)
        report()
    }

    /// Two-finger double-tap toggles Fit and the click zoom, like a click.
    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: canvas.convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard !event.modifierFlags.intersection([.command, .option]).isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
        let target = min(maxMagnification, max(fitMagnification, magnification * factor))
        isLiveZooming = true
        setMagnification(target, centeredAt: canvas.convert(event.locationInWindow, from: nil))
        // Scroll events have no end of their own (a mouse wheel has no phases); settle shortly after the last.
        scrollZoomEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endLiveZoom() }
        }
        scrollZoomEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
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
    private var contents: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Never redrawn by AppKit while zooming: the layer's contents are the photo, scaled on the GPU.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func setImage(_ image: NSImage?) {
        guard image !== currentImage else { return }
        currentImage = image
        contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contentsGravity = .resize
        layer?.contents = contents
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
    @Binding var zoom: ZoomLevel
    let report: ZoomReport
    /// A single menu instead of the segmented buttons, for narrow columns.
    var compact = false

    private var percentText: String {
        report.percent > 0 ? "\(Int(report.percent.rounded()))%" : "Zoom"
    }

    var body: some View {
        if compact {
            Menu(percentText) {
                ForEach(ZoomLevel.presets, id: \.self) { level in
                    Button(level.label) { zoom = level }
                }
            }
            .fixedSize()
            .help("Zoom (Z toggles Fit and 100%; pinch, or hold ⌥ and scroll)")
        } else {
            HStack(spacing: 8) {
                Picker("Zoom", selection: $zoom) {
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
