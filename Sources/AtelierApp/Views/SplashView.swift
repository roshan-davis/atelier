import AppKit
import AtelierCore
import ImageIO
import SwiftUI
import Vision

/// An image ready for the splash: loaded at splash size, with how it fills the splash.
struct SplashImage {
    let image: NSImage
    let layout: Splash.Layout

    /// Loads at up to 2000 px (enough for 1600x1000 at 2x) and finds the subject with Vision,
    /// so a crop keeps it in frame. Nil when the file can't be read.
    static func load(_ url: URL) async -> SplashImage? {
        await Task.detached(priority: .userInitiated) { () -> SplashImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 2000,
                  ] as CFDictionary)
            else { return nil }
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            switch Splash.layout(imageSize: size, focus: subjectCenter(cgImage)) {
            case .framed:
                return SplashImage(image: NSImage(cgImage: cgImage, size: size), layout: .framed)
            case .fill(let crop):
                let pixels = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                                    width: crop.width * size.width, height: crop.height * size.height).integral
                let cropped = cgImage.cropping(to: pixels) ?? cgImage
                return SplashImage(image: NSImage(cgImage: cropped, size: pixels.size), layout: .fill(crop: crop))
            }
        }.value
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
}

/// The launch splash: the photo, the app's name and tagline at top left, and Don't show again.
/// It is always 800x500 and always dark, whatever the theme, since it sits on a photo.
struct SplashView: View {
    // Placeholders until Rosh picks the name and tagline.
    static let title = "Atelier"
    static let tagline = "Develop with intent."

    let image: SplashImage?
    var onDismiss: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    // Not private, so the memberwise init stays usable from LayoutSnapshots.
    @AppStorage(Splash.showKey) var showAtLaunch = true

    var body: some View {
        ZStack {
            photo
            // Darken the top and bottom just enough for white text on bright photos.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Splash.size.height * 0.42)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Splash.size.height * 0.2)
            }
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.title)
                    .font(.system(size: 46, weight: .light))
                    .tracking(1.5)
                Text(Self.tagline)
                    .font(.system(size: 16))
                    .opacity(0.85)
                    .padding(.top, 2)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    // Bottom right: Rosh's watermark sits bottom left on their photos.
                    Toggle("Don't show again", isOn: Binding(get: { !showAtLaunch }, set: { showAtLaunch = !$0 }))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
            .padding(EdgeInsets(top: 30, leading: 34, bottom: 18, trailing: 22))
        }
        .frame(width: Splash.size.width, height: Splash.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .onHover(perform: onHover)
    }

    @ViewBuilder private var photo: some View {
        switch image?.layout {
        case .fill:
            Image(nsImage: image!.image)
                .resizable()
                .scaledToFill()
                .frame(width: Splash.size.width, height: Splash.size.height)
                .clipped()
        case .framed:
            let nsImage = image!.image
            let isTall = nsImage.size.width / max(nsImage.size.height, 1) < Splash.aspect
            ZStack(alignment: isTall ? .trailing : .center) {
                // The image itself, blurred and darkened, fills the space around it.
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Splash.size.width, height: Splash.size.height)
                    .blur(radius: 40, opaque: true)
                    .overlay(Color.black.opacity(0.5))
                    .clipped()
                // Tall images sit on the right, leaving the left for the name.
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .padding(isTall ? EdgeInsets(top: 28, leading: 28, bottom: 28, trailing: 40)
                                    : EdgeInsets(top: 96, leading: 28, bottom: 44, trailing: 28))
            }
            .frame(width: Splash.size.width, height: Splash.size.height)
        case nil:
            // No images in the folder.
            LinearGradient(colors: [Color(white: 0.2), Color(red: 0.08, green: 0.1, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Shows the splash in its own borderless window over the library window, and fades it out
/// after a few seconds, or at once on a click. It stays while the pointer is over it.
@MainActor
final class SplashController {
    static let shared = SplashController()
    private var window: NSPanel?
    private var hovering = false

    /// The built-in images, copied into the Splash folder the first time.
    static var builtInImages: [URL] {
        let urls = (Bundle.module.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
            + (Bundle.module.urls(forResourcesWithExtension: "jpg", subdirectory: "Splash") ?? [])
        return urls.filter { $0.lastPathComponent.hasPrefix("splash-") }
    }

    static func installFolder() {
        try? Splash.installBuiltInImages(builtInImages)
    }

    func showAtLaunch() {
        guard UserDefaults.standard.object(forKey: Splash.showKey) as? Bool ?? true else { return }
        show()
    }

    /// Shows the next image in the rotation.
    func show() {
        Self.installFolder()
        let next = Splash.nextImage(from: Splash.images())
        Task {
            var image: SplashImage?
            if let next { image = await SplashImage.load(next) }
            present(image)
        }
    }

    private func present(_ image: SplashImage?) {
        window?.close()
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Splash.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: SplashView(
            image: image,
            onDismiss: { [weak self] in self?.dismiss() },
            onHover: { [weak self] in self?.hovering = $0 }))
        panel.center()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        window = panel
        Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(3))
            while self?.hovering == true { try? await Task.sleep(for: .milliseconds(250)) }
            if let panel, self?.window === panel { self?.dismiss() }
        }
    }

    func dismiss() {
        guard let panel = window else { return }
        window = nil
        hovering = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.close() })
    }
}
