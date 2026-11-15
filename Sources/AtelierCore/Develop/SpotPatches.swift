import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Remove tool's generated fills (AT-066 step 4): one image per Generative AI spot, kept in
/// Application Support/Atelier/Spot Patches as `<id>.png` with how it was made in `<id>.json`.
/// Edits stay settings: the spot names its patch, and the original is never written.
public final class SpotPatches: @unchecked Sendable {
    public static let shared = SpotPatches()

    public let folder: URL
    private let images = NSCache<NSString, CIImage>()
    private let lock = NSLock()
    /// Ids whose file was looked for and is missing, so a render doesn't look again every frame.
    private var missing: Set<UUID> = []

    public init(folder: URL? = nil) {
        self.folder = folder ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Atelier/Spot Patches", isDirectory: true)
    }

    public func url(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).png") }

    /// Saves `image` (sRGB, the generated area at any size) and its provenance as patch `id`.
    public func save(_ image: CGImage, id: UUID, provenance: [String: Any]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = url(for: id)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw AIError("Can't write to \(folder.path).") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AIError("Saving the generated fill failed.") }
        if let json = try? JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys, .prettyPrinted]) {
            try? json.write(to: folder.appendingPathComponent("\(id.uuidString).json"))
        }
        lock.lock()
        missing.remove(id)
        lock.unlock()
    }

    /// The patch's image as saved, or nil when its file is gone.
    func loadedImage(for id: UUID) -> CIImage? {
        let key = id.uuidString as NSString
        if let cached = images.object(forKey: key) { return cached }
        lock.lock()
        let known = missing.contains(id)
        lock.unlock()
        guard !known else { return nil }
        guard let loaded = CIImage(contentsOf: url(for: id)) else {
            lock.lock()
            missing.insert(id)
            lock.unlock()
            return nil
        }
        images.setObject(loaded, forKey: key)
        return loaded
    }

    /// The patch placed on `image` (the photo with the spots before it, uncropped, in the working
    /// space), scaled to its size and shifted by how much the area's average color has changed
    /// since the patch was made (White Balance, Exposure). Nil when its file is gone.
    func placed(_ patch: DevelopSettings.Spot.Patch, on image: CIImage) -> CIImage? {
        guard let source = loadedImage(for: patch.id), !source.extent.isEmpty else { return nil }
        let extent = image.extent
        let photo = extent.size
        // Core Image's y axis points up.
        let region = CGRect(x: extent.minX + CGFloat(patch.region.x) * photo.width,
                            y: extent.minY + (1 - CGFloat(patch.region.y + patch.region.height)) * photo.height,
                            width: CGFloat(patch.region.width) * photo.width,
                            height: CGFloat(patch.region.height) * photo.height)
        guard region.width >= 1, region.height >= 1 else { return nil }
        let placed = source
            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: region.width / source.extent.width,
                                               y: region.height / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
            .cropped(to: region)
        guard let ratio = Self.colorShift(from: patch.mean, to: image, in: region) else { return placed }
        return placed.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: ratio])
            .cropped(to: region)
    }

    /// An endless image of (the area's average now) / `mean`, per channel, kept to 1/4...4; nil
    /// when `mean` is too dark to divide by.
    static func colorShift(from mean: [Double], to image: CIImage, in region: CGRect) -> CIImage? {
        guard mean.count == 3, mean.allSatisfy({ $0 > 1e-4 && $0.isFinite }) else { return nil }
        let now = image.cropped(to: region)
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
            .clampedToExtent()
        return now
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(1 / mean[0]), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(1 / mean[1]), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(1 / mean[2]), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0.25, y: 0.25, z: 0.25, w: 1),
                "inputMaxComponents": CIVector(x: 4, y: 4, z: 4, w: 1),
            ])
    }

    /// The average color (red, green, blue in the working space) of `region` of `image`.
    static func mean(of image: CIImage, in region: CGRect, context: CIContext) -> [Double]? {
        let average = image.cropped(to: region)
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            // No color space: the values stay in the working space, as the renderer sees them.
            context.render(average, toBitmap: buffer.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: average.extent.minX, y: average.extent.minY, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        let rgb = pixel.prefix(3).map { Double($0) }
        return rgb.allSatisfy(\.isFinite) ? rgb : nil
    }
}
