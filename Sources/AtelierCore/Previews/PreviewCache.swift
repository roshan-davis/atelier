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
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: original.path])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Size.preview.rawValue,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: original.path])
        }
        let shard = url(for: assetID, size: .preview).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        try writeJPEG(preview, to: url(for: assetID, size: .preview))

        let thumbnail = Self.scaled(preview, maxPixelSize: Size.thumbnail.rawValue) ?? preview
        try writeJPEG(thumbnail, to: url(for: assetID, size: .thumbnail))
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
