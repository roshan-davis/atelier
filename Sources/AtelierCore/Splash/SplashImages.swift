import CoreGraphics
import Foundation

/// The launch splash: which image to show next, and how an image of any size fills the
/// fixed 800x500 splash without being stretched.
public enum Splash {
    /// The splash is always this size, in points (shown at 2x on Retina: 1600x1000 px).
    public static let size = CGSize(width: 800, height: 500)
    public static var aspect: CGFloat { size.width / size.height }

    public static let showKey = "splash.show"
    public static let nextIndexKey = "splash.nextIndex"

    /// Settings > General > Show splash screen at launch; on unless turned off.
    public static var showsAtLaunch: Bool {
        UserDefaults.standard.object(forKey: showKey) as? Bool ?? true
    }

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    /// Images here are shown in turn, one per launch. It starts with the built-in images, and
    /// Rosh can add, remove or replace them in Finder without rebuilding.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Splash", isDirectory: true)
    }

    /// Creates the folder with the built-in images the first time. Once the folder exists it is
    /// left alone, so images Rosh removed don't come back.
    public static func installBuiltInImages(_ builtIn: [URL], into folder: URL = folder) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in builtIn {
            try? fm.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }

    /// The images in the folder, in name order, so the rotation is predictable.
    public static func images(in folder: URL = folder) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The image for this launch, moving the rotation on by one. Nil when the folder is empty.
    public static func nextImage(from images: [URL], defaults: UserDefaults = .standard) -> URL? {
        guard !images.isEmpty else { return nil }
        let index = max(0, defaults.integer(forKey: nextIndexKey)) % images.count
        defaults.set((index + 1) % images.count, forKey: nextIndexKey)
        return images[index]
    }

    public enum Layout: Equatable {
        /// Fill the splash, cropping only this part of the image (normalized, origin top left).
        case fill(crop: CGRect)
        /// The whole image, fitted inside the splash over a blurred, darkened copy of itself.
        case framed
    }

    /// Every image fills the splash (Rosh, Oct 28, 2026: no space around portraits), cropped
    /// around the subject. `focus` is the subject's center, normalized with the origin at the
    /// top left. Only an image with no size falls back to framed.
    public static func layout(imageSize: CGSize, focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Layout {
        guard imageSize.width > 0, imageSize.height > 0 else { return .framed }
        return .fill(crop: fillCrop(imageAspect: imageSize.width / imageSize.height, focus: focus))
    }

    /// The largest crop of the splash's shape, centered on `focus` as far as the edges allow.
    static func fillCrop(imageAspect: CGFloat, focus: CGPoint) -> CGRect {
        if imageAspect > aspect {
            let width = aspect / imageAspect
            let x = min(max(focus.x - width / 2, 0), 1 - width)
            return CGRect(x: x, y: 0, width: width, height: 1)
        } else {
            let height = imageAspect / aspect
            let y = min(max(focus.y - height / 2, 0), 1 - height)
            return CGRect(x: 0, y: y, width: 1, height: height)
        }
    }
}
