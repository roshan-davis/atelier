import AppKit
import AtelierCore
import CoreImage
import ImageIO
import QuartzCore
import Vision

/// An image ready for the splash's photo area.
struct SplashImage {
    /// Already cropped to the photo area when filling; the whole image when framed.
    let image: CGImage
    /// A small blurred copy, behind a framed image.
    let backdrop: CGImage?
    let layout: Splash.Layout

    /// Loads at up to 1600 px and finds the subject with Vision, so a crop keeps it in frame.
    /// Synchronous and quick (well under 0.1 s), since at launch nothing else may run first.
    static func load(_ url: URL) -> SplashImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary)
        else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        switch Splash.layout(imageSize: size, focus: subjectCenter(cgImage)) {
        case .framed:
            return SplashImage(image: cgImage, backdrop: blurred(cgImage), layout: .framed)
        case .fill(let crop):
            let pixels = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                                width: crop.width * size.width, height: crop.height * size.height).integral
            return SplashImage(image: cgImage.cropping(to: pixels) ?? cgImage, backdrop: nil, layout: .fill(crop: crop))
        }
    }

    /// The center of what draws the eye, origin top left; the image center if Vision finds nothing.
    private static func subjectCenter(_ image: CGImage) -> CGPoint {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let boxes = request.results?.first?.salientObjects?.map(\.boundingBox) ?? []
        guard let first = boxes.first else { return CGPoint(x: 0.5, y: 0.5) }
        let box = boxes.dropFirst().reduce(first) { $0.union($1) }
        // Vision's origin is bottom left.
        return CGPoint(x: box.midX, y: 1 - box.midY)
    }

    private static func blurred(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = 240 / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: small.extent)
        return blurContext.createCGImage(blurred, from: small.extent)
    }

    /// Made once and reused, as Apple advises for Core Image contexts (AT-076 M2).
    private static let blurContext = CIContext()
}

/// The splash: the photo on top at 16:10 with nothing drawn over it, and a dark strip below
/// with the name and tagline on the left and the startup status and Don't show again on the
/// right. A hairline between them fills as startup steps finish.
///
/// The text is Core Animation text layers, not text fields: a status change only needs a
/// CATransaction.flush() to reach the screen, without an AppKit redraw, which isn't allowed
/// while SwiftUI is still setting up the app and the catalog is opening.
final class SplashContentView: NSView {
    // Placeholders until Rosh picks the name and tagline.
    static let title = "Atelier"
    static let tagline = "Develop with intent."

    static let stripHeight: CGFloat = 72
    static var windowSize: CGSize { CGSize(width: Splash.size.width, height: Splash.size.height + stripHeight) }

    var onDismiss: () -> Void = {}

    private let statusLayer = CATextLayer()
    private let progressLayer = CALayer()
    private let checkbox = NSButton(checkboxWithTitle: "Don't show again", target: nil, action: nil)

    init(image: SplashImage?) {
        super.init(frame: CGRect(origin: .zero, size: Self.windowSize))
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        guard let layer else { return }
        layer.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = NSColor(white: 1, alpha: 0.1).cgColor

        // Origin is bottom left: the strip is at the bottom, the photo above it.
        let photoFrame = CGRect(x: 0, y: Self.stripHeight, width: Splash.size.width, height: Splash.size.height)
        layer.addSublayer(photoLayer(image, frame: photoFrame))

        let rule = CALayer()
        rule.frame = CGRect(x: 0, y: Self.stripHeight - 1, width: bounds.width, height: 1)
        rule.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer.addSublayer(rule)
        progressLayer.frame = CGRect(x: 0, y: Self.stripHeight - 1, width: 0, height: 1)
        progressLayer.backgroundColor = NSColor(white: 1, alpha: 0.55).cgColor
        layer.addSublayer(progressLayer)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let texts: [(CATextLayer, String, NSFont, NSColor, CGRect)] = [
            (CATextLayer(), Self.title, NSFont.systemFont(ofSize: 22, weight: .light), NSColor.white,
             CGRect(x: 24, y: 30, width: 260, height: 30)),
            (CATextLayer(), Self.tagline, NSFont.systemFont(ofSize: 12), NSColor(white: 1, alpha: 0.6),
             CGRect(x: 25, y: 12, width: 260, height: 17)),
            (statusLayer, "", NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), NSColor(white: 1, alpha: 0.6),
             CGRect(x: 300, y: 38, width: bounds.width - 300 - 24, height: 16)),
        ]
        for (textLayer, string, font, color, frame) in texts {
            textLayer.string = string
            textLayer.font = font
            textLayer.fontSize = font.pointSize
            textLayer.foregroundColor = color.cgColor
            textLayer.contentsScale = scale
            textLayer.frame = frame
            layer.addSublayer(textLayer)
        }
        statusLayer.alignmentMode = .right
        statusLayer.truncationMode = .middle

        checkbox.controlSize = .small
        checkbox.font = .systemFont(ofSize: 11)
        checkbox.target = self
        checkbox.action = #selector(toggleShowAtLaunch)
        checkbox.state = Splash.showsAtLaunch ? .off : .on
        addSubview(checkbox)
        checkbox.sizeToFit()
        checkbox.setFrameOrigin(CGPoint(x: bounds.width - 22 - checkbox.frame.width, y: 12))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func photoLayer(_ image: SplashImage?, frame: CGRect) -> CALayer {
        let container = CALayer()
        container.frame = frame
        container.masksToBounds = true
        let bounds = CGRect(origin: .zero, size: frame.size)
        guard let image else {
            // No images in the folder.
            let gradient = CAGradientLayer()
            gradient.frame = bounds
            gradient.colors = [NSColor(white: 0.2, alpha: 1).cgColor,
                               NSColor(red: 0.08, green: 0.1, blue: 0.13, alpha: 1).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            container.addSublayer(gradient)
            return container
        }
        switch image.layout {
        case .fill:
            container.contents = image.image
            container.contentsGravity = .resizeAspectFill
        case .framed:
            // The image's own blurred colors fill the space around it, darkened so it stands out.
            container.contents = image.backdrop
            container.contentsGravity = .resizeAspectFill
            let shade = CALayer()
            shade.frame = bounds
            shade.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
            container.addSublayer(shade)
            let photo = CALayer()
            photo.frame = Self.fitted(CGSize(width: image.image.width, height: image.image.height),
                                      in: bounds.insetBy(dx: 28, dy: 24))
            photo.contents = image.image
            photo.shadowColor = .black
            photo.shadowOpacity = 0.5
            photo.shadowRadius = 16
            photo.shadowOffset = CGSize(width: 0, height: -6)
            photo.shadowPath = CGPath(rect: CGRect(origin: .zero, size: photo.frame.size), transform: nil)
            container.addSublayer(photo)
        }
        return container
    }

    private static func fitted(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Shows a startup step; `progress` is 0 to 1.
    func setStatus(_ text: String, progress: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusLayer.string = text
        progressLayer.frame.size.width = bounds.width * min(max(progress, 0), 1)
        CATransaction.commit()
    }

    @objc private func toggleShowAtLaunch() {
        UserDefaults.standard.set(checkbox.state == .off, forKey: Splash.showKey)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDismiss() }
}

/// Shows the splash in its own borderless window. At launch it goes up as the app starts
/// (applicationWillFinishLaunching), shows each real startup step, then fades once the library
/// has loaded.
@MainActor
final class SplashController {
    static let shared = SplashController()
    private var window: NSPanel?
    private var content: SplashContentView?
    private var launched = false
    /// The latest step, kept in case it arrives before the splash is up.
    private var status = ("Starting…", 0.05)
    private var finished = false

    /// The built-in images, copied into the Splash folder the first time.
    static var builtInImages: [URL] {
        let urls = (AtelierResources.bundle.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
            + (AtelierResources.bundle.urls(forResourcesWithExtension: "jpg", subdirectory: "Splash") ?? [])
        return urls.filter { $0.lastPathComponent.hasPrefix("splash-") }
    }

    static func installFolder() {
        try? Splash.installBuiltInImages(builtInImages)
    }

    private static func nextImage() -> SplashImage? {
        installFolder()
        return Splash.nextImage(from: Splash.images()).flatMap(SplashImage.load)
    }

    /// Called from applicationWillFinishLaunching, outside any SwiftUI update, so the window
    /// can be drawn straight away.
    func showAtLaunch() {
        guard !launched, LayoutSnapshots.outputFolder == nil, Splash.showsAtLaunch else { return }
        launched = true
        // Launched from Xcode or `swift run` there is no app bundle; windows need a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
        present(Self.nextImage())
        report(status.0, progress: status.1)
        if finished {
            // The library loaded before the splash could go up.
            dismiss(after: 1)
        } else {
            // In case the library never reports in.
            dismiss(after: 20)
        }
    }

    /// Settings > General > Preview Splash Screen.
    func preview() {
        present(Self.nextImage())
        content?.setStatus("Preview", progress: 1)
        dismiss(after: 3)
    }

    /// Shows a startup step. It can come while SwiftUI is setting up the app with the main
    /// thread busy, so it only commits the layer change rather than asking AppKit to redraw.
    func report(_ text: String, progress: Double) {
        status = (text, progress)
        guard let content else { return }
        content.setStatus(text, progress: progress)
        CATransaction.flush()
    }

    /// The last step: shows it, then fades out a second later (Rosh, Oct 28, 2026).
    func finishLaunch(_ text: String) {
        finished = true
        report(text, progress: 1)
        guard window != nil else { return }
        dismiss(after: 1)
    }

    private func present(_ image: SplashImage?) {
        window?.close()
        let content = SplashContentView(image: image)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: SplashContentView.windowSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        content.onDismiss = { [weak self] in self?.dismiss() }
        panel.center()
        panel.orderFrontRegardless()
        // Draw now: the run loop may not turn again until the catalog has opened. Safe here, since
        // present is only called from the app delegate and from a button, never inside a SwiftUI update.
        panel.display()
        CATransaction.flush()
        window = panel
        self.content = content
    }

    private func dismiss(after seconds: Double) {
        let panel = window
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if let self, let panel, self.window === panel { self.dismiss() }
        }
    }

    func dismiss() {
        guard let panel = window else { return }
        window = nil
        content = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.close() })
    }
}
