import AppKit
import QuartzCore
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
        ZoomTrace.count("updateNSView", "zoom \(zoom.level.label)")
        view.menuProvider = menu
        view.onReport = onReport
        let zoom = self.zoom
        view.onZoomChange = { level in
            if zoom.level != level { zoom.level = level }
        }
        view.setImage(image, pixelSize: pixelSize)
        view.setDimmed(dimmed)
        view.apply(zoom.level)
    }
}

final class ZoomScrollView: NSScrollView {
    private let canvas = ZoomCanvasView()
    private(set) var level: ZoomLevel = .fit
    private var documentSize = CGSize.zero
    private var lastReport = ZoomReport()
    private let padding: CGFloat = 16

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
        NotificationCenter.default.addObserver(self, selector: #selector(didEndMagnify),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Content

    func setImage(_ image: NSImage?, pixelSize: CGSize?) {
        let start = CACurrentMediaTime()
        let changed = canvas.setImage(image)
        if changed {
            ZoomTrace.count("setImage", "\(canvas.contentsDescription), took \(ZoomTrace.milliseconds(since: start))")
        }
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
        ZoomTrace.count("documentSize changed", "\(documentSize) → \(size)")
        documentSize = size
        canvas.frame = CGRect(origin: .zero, size: size)
        applyLevel(level, anchor: nil)
    }

    func setDimmed(_ dimmed: Bool) {
        canvas.alphaValue = dimmed ? 0.4 : 1
    }

    // MARK: Zoom

    func apply(_ newLevel: ZoomLevel) {
        guard newLevel != level else { return }
        ZoomTrace.count("apply from SwiftUI", "\(level.label) → \(newLevel.label)")
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
        ZoomTrace.count("applyLevel", "\(newLevel.label), magnification \(magnification) → \(magnification(for: newLevel))")
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
        ZoomTrace.count("setFrameSize", "\(frame.size) → \(newSize), level \(level.label)")
        super.setFrameSize(newSize)
        if level == .fit || level == .fill {
            magnification = magnification(for: level)
        }
        report()
    }

    @objc private func didEndMagnify() {
        ZoomTrace.count("didEndLiveMagnify", "magnification \(magnification)")
        level = .percent(Double(magnification * 100))
        onZoomChange?(level)
        report()
    }

    // MARK: Tracing

    private var link: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(traceFrame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func traceFrame(_ link: CADisplayLink) {
        ZoomTrace.frame(link.timestamp, interval: link.targetTimestamp - link.timestamp)
    }

    private var layerState: String {
        let layer = canvas.layer
        let transform = layer.map { CATransform3DIsIdentity($0.transform) ? "identity" : "\(CATransform3DGetAffineTransform($0.transform))" } ?? "-"
        let clipTransform = contentView.layer.map { CATransform3DIsIdentity($0.sublayerTransform) ? "identity" : "\(CATransform3DGetAffineTransform($0.sublayerTransform))" } ?? "-"
        return "canvas frame \(canvas.frame), layer bounds \(layer?.bounds ?? .zero), contentsScale \(layer?.contentsScale ?? 0), "
            + "transform \(transform), clip sublayerTransform \(clipTransform), clip bounds \(contentView.bounds), "
            + "contents \(layer?.contents == nil ? "nil" : "set"), \(canvas.contentsDescription), magnification \(magnification)"
    }

    override func magnify(with event: NSEvent) {
        ZoomTrace.touch("pinch")
        if event.phase == .began { ZoomTrace.log("layer at start: \(layerState)") }
        let before = magnification
        let start = CACurrentMediaTime()
        super.magnify(with: event)
        ZoomTrace.count("magnify", String(format: "phase %lu, %.3f → %.3f, handled in %@",
                                          event.phase.rawValue, before, magnification, ZoomTrace.milliseconds(since: start)))
        if event.phase == .ended || event.phase == .cancelled { ZoomTrace.log("layer at end: \(layerState)") }
    }

    override func smartMagnify(with event: NSEvent) {
        ZoomTrace.touch("smart magnify")
        super.smartMagnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        ZoomTrace.touch("scroll")
        let start = CACurrentMediaTime()
        defer {
            ZoomTrace.count("scrollWheel", String(format: "phase %lu, momentum %lu, Δ(%.1f, %.1f), handled in %@",
                                                  event.phase.rawValue, event.momentumPhase.rawValue,
                                                  event.scrollingDeltaX, event.scrollingDeltaY, ZoomTrace.milliseconds(since: start)))
        }
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
        ZoomTrace.count("report", "\(Int(report.percent))%, fit \(Int(report.fitPercent))%")
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

    /// Returns whether the image changed.
    @discardableResult
    func setImage(_ image: NSImage?) -> Bool {
        guard image !== currentImage else { return false }
        currentImage = image
        layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return true
    }

    var contentsDescription: String {
        guard let contents = layer?.contents else { return "no image" }
        guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return "contents \(type(of: contents))" }
        let image = contents as! CGImage
        return "image \(image.width)×\(image.height), \(image.bitsPerPixel) bpp, \(image.colorSpace?.name.map { $0 as String } ?? "no color space"), "
            + "alpha \(image.alphaInfo.rawValue), bitmapInfo \(image.bitmapInfo.rawValue)"
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
