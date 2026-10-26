import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 256 px thumbnails and 2560 px previews, stored as JPEG in Previews/<shard>/<id>-<size>.jpg.
/// Previews keep offline photos browsable when the NAS is off.
public final class PreviewCache: Sendable {
    public enum Size: Int, Sendable, CaseIterable {
        case thumbnail = 256
        case preview = 2560
    }

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func url(for assetID: Int64, size: Size) -> URL {
        rootURL
            .appendingPathComponent(String(format: "%02x", assetID & 0xff), isDirectory: true)
            .appendingPathComponent("\(assetID)-\(size.rawValue).jpg")
    }

    public func hasPreviews(for assetID: Int64) -> Bool {
        Size.allCases.allSatisfy { FileManager.default.fileExists(atPath: url(for: assetID, size: $0).path) }
    }

    /// Renders both sizes from the original. RAW files are decoded by Apple's RAW engine.
    public func generate(for assetID: Int64, from original: URL) throws {
        try generateThumbnail(for: assetID, from: original)
        try generatePreview(for: assetID, from: original)
    }

    /// The fast path: uses the photo's embedded preview when it is big enough, so a RAW
    /// thumbnail costs a JPEG decode instead of a full RAW render.
    public func generateThumbnail(for assetID: Int64, from original: URL) throws {
        let source = try Self.imageSource(original)
        let maxSize = Size.thumbnail.rawValue
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        // Embedded thumbnails are sometimes tiny (160 px); render from the image instead.
        if let small = image, max(small.width, small.height) < maxSize * 3 / 4 {
            image = nil
        }
        if image == nil {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: original.path])
        }
        try write(image, assetID: assetID, size: .thumbnail)
    }

    /// The 2560 px loupe preview, rendered from the full image.
    public func generatePreview(for assetID: Int64, from original: URL) throws {
        let source = try Self.imageSource(original)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Size.preview.rawValue,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: original.path])
        }
        try write(preview, assetID: assetID, size: .preview)
    }

    public func has(_ size: Size, for assetID: Int64) -> Bool {
        FileManager.default.fileExists(atPath: url(for: assetID, size: size).path)
    }

    private static func imageSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return source
    }

    private func write(_ image: CGImage, assetID: Int64, size: Size) throws {
        let destination = url(for: assetID, size: size)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Write beside the target and swap it in, so readers never see a half-written file.
        let temporary = destination.deletingPathExtension().appendingPathExtension("tmp.jpg")
        try writeJPEG(image, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    public func remove(for assetID: Int64) {
        for size in Size.allCases {
            try? FileManager.default.removeItem(at: url(for: assetID, size: size))
        }
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxPixelSize else { return image }
        let scale = Double(maxPixelSize) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        // Keep the source color space when it is RGB; grayscale and others fall back to sRGB.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
