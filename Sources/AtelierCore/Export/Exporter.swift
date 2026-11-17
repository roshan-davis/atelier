import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case jpeg, heic, tiff, png

    public var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF (16-bit)"
        case .png: return "PNG"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tif"
        case .png: return "png"
        }
    }

    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .png: return .png
        }
    }

    public var hasQuality: Bool { self == .jpeg || self == .heic }
    var isSixteenBit: Bool { self == .tiff }
}

public enum ExportColorSpace: String, CaseIterable, Codable, Sendable {
    case sRGB, displayP3, adobeRGB, proPhoto

    public var label: String {
        switch self {
        case .sRGB: return "sRGB (web and social)"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB (1998)"
        case .proPhoto: return "ProPhoto RGB"
        }
    }

    var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        case .proPhoto: return CGColorSpace(name: CGColorSpace.rommrgb)!
        }
    }

    /// The choices offered when exporting; ProPhoto is for Edit In.
    public static let exportChoices: [ExportColorSpace] = [.sRGB, .displayP3, .adobeRGB]
}

public enum ExportMetadata: String, CaseIterable, Codable, Sendable {
    case all, allExceptLocation, none

    public var label: String {
        switch self {
        case .all: return "All metadata"
        case .allExceptLocation: return "All except location"
        case .none: return "None"
        }
    }
}

public enum ExportSharpening: String, CaseIterable, Codable, Sendable {
    case none, screen

    public var label: String {
        switch self {
        case .none: return "None"
        case .screen: return "For screen"
        }
    }
}

public struct ExportSettings: Codable, Hashable, Sendable {
    public var format: ExportFormat = .jpeg
    /// 0...1, for JPEG and HEIC.
    public var quality: Double = 0.9
    /// Long edge in pixels; nil keeps the original size.
    public var longEdge: Int?
    public var colorSpace: ExportColorSpace = .sRGB
    public var metadata: ExportMetadata = .allExceptLocation
    public var sharpening: ExportSharpening = .none
    /// Drawn after resizing and sharpening; nil for none.
    public var watermark: ExportWatermark?
    public var destination: URL

    public init(destination: URL) {
        self.destination = destination
    }
}

public struct ExportProgress: Sendable {
    public var processed: Int
    public var total: Int
    public var filename: String
}

public struct ExportFailure: Sendable, Hashable {
    public var filename: String
    public var reason: String
}

public struct ExportResult: Sendable {
    public var exported: [URL] = []
    public var failures: [ExportFailure] = []
}

/// Renders photos with their develop settings at full quality and writes them to a folder.
/// Originals are only read; nothing in the catalog changes.
public final class Exporter: Sendable {
    private let catalog: Catalog
    private let renderer: DevelopRenderer
    /// Photos exported at once by `run`. Export used one core of the CPU and the GPU in turn;
    /// two at once overlap them. On 12 Z f RAWs (AT-076 P3, `ExportTimingTests`): full-size
    /// JPEG 3.49 → 2.19 s, peak 2.6 → 3.4 GB (TIFF 4 GB), back to 0.25 GB within 3 s; a third adds 7%.
    let photosInFlight: Int

    public convenience init(catalog: Catalog, renderer: DevelopRenderer = .shared) {
        self.init(catalog: catalog, renderer: renderer,
                  photosInFlight: Self.defaultPhotosInFlight(physicalMemory: ProcessInfo.processInfo.physicalMemory))
    }

    /// Two photos at once, one on an 8 GB Mac: two full-size 16-bit TIFFs peak at about 4 GB.
    static func defaultPhotosInFlight(physicalMemory: UInt64) -> Int {
        physicalMemory > 8 * 1_073_741_824 ? 2 : 1
    }

    init(catalog: Catalog, renderer: DevelopRenderer, photosInFlight: Int) {
        self.catalog = catalog
        self.renderer = renderer
        self.photosInFlight = max(1, photosInFlight)
    }

    public func run(assetIDs: [Int64], settings: ExportSettings,
                    progress: (@Sendable (ExportProgress) -> Void)? = nil) async -> ExportResult {
        var result = ExportResult()
        do {
            try FileManager.default.createDirectory(at: settings.destination, withIntermediateDirectories: true)
        } catch {
            result.failures.append(ExportFailure(filename: settings.destination.lastPathComponent,
                                                 reason: "Can't create the export folder: \(error.localizedDescription)"))
            return result
        }
        // Up to `photosInFlight` photos at once; results keep the photos' order.
        var outcomes = [Result<URL, Error>?](repeating: nil, count: assetIDs.count)
        var finished = 0
        await withTaskGroup(of: (Int, Result<URL, Error>).self) { group in
            var next = 0
            func startNext() {
                guard next < assetIDs.count, !Task.isCancelled else { return }
                let index = next, id = assetIDs[index]
                next += 1
                group.addTask {
                    (index, Result { try autoreleasepool { try self.export(id, settings: settings) } })
                }
            }
            for _ in 0..<photosInFlight { startNext() }
            progress?(ExportProgress(processed: 0, total: assetIDs.count, filename: filename(assetIDs.first)))
            for await (index, outcome) in group {
                outcomes[index] = outcome
                finished += 1
                progress?(ExportProgress(processed: finished, total: assetIDs.count,
                                         filename: filename(next < assetIDs.count ? assetIDs[next] : nil)))
                startNext()
            }
        }
        for (id, outcome) in zip(assetIDs, outcomes) {
            switch outcome {
            case .success(let url): result.exported.append(url)
            case .failure(let error): result.failures.append(ExportFailure(filename: filename(id), reason: error.localizedDescription))
            case nil: break  // cancelled before it started
            }
        }
        return result
    }

    /// The photo's file name for progress and failures ("" when there is none).
    private func filename(_ id: Int64?) -> String {
        guard let id else { return "" }
        return (try? catalog.detail(for: id))?.asset.filename ?? "Photo \(id)"
    }

    /// Exports one photo and returns the written file. `baseName` replaces the original's
    /// name; with `develop` false the photo is rendered without its develop settings.
    /// `lensBlur` renders the photo's Lens Blur too: only the Lens Blur mode's Save asks for it
    /// (see `DevelopSession.rendersLensBlur`).
    public func export(_ assetID: Int64, settings: ExportSettings, baseName: String? = nil,
                       develop applyDevelop: Bool = true, lensBlur: Bool = false) throws -> URL {
        guard let detail = try catalog.detail(for: assetID) else { throw ExportError("The photo is no longer in the catalog.") }
        guard let source = detail.fileURL, FileManager.default.fileExists(atPath: source.path) else {
            throw ExportError("The original is offline. Connect its drive and export again.")
        }
        let develop = applyDevelop ? try catalog.developSettings(for: assetID) : .neutral
        // A crop keeps only part of the photo, so decode larger to still reach the long edge.
        var decodeEdge = settings.longEdge
        if let longEdge = settings.longEdge, let crop = develop.crop,
           let width = detail.asset.width, let height = detail.asset.height, width > 0, height > 0 {
            let full = CGSize(width: width, height: height)
            let cropped = crop.outputSize(full)
            let fraction = max(cropped.width, cropped.height) / max(full.width, full.height)
            decodeEdge = Int((Double(longEdge) / max(0.05, Double(fraction))).rounded(.up))
        }
        guard let session = renderer.session(for: source, maxPixelSize: decodeEdge) else {
            throw ExportError("This file can't be rendered.")
        }
        session.rendersLensBlur = lensBlur
        guard var image = session.image(with: develop) else {
            throw ExportError("This file can't be rendered.")
        }

        // RAW decode scales approximately; land exactly on the requested long edge.
        if let longEdge = settings.longEdge {
            let current = max(image.extent.width, image.extent.height)
            if current > CGFloat(longEdge) + 0.5 {
                let scale = CIFilter.lanczosScaleTransform()
                scale.inputImage = image
                scale.scale = Float(CGFloat(longEdge) / current)
                scale.aspectRatio = 1
                image = scale.outputImage ?? image
            }
        }
        if settings.sharpening == .screen {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = image
            sharpen.sharpness = 0.4
            sharpen.radius = 1.2
            image = sharpen.outputImage ?? image
        }
        image = image.cropped(to: image.extent.integral)
        image = Watermark.apply(settings.watermark, to: image)

        let format: CIFormat = settings.format.isSixteenBit ? .RGBA16 : .RGBA8
        // Deferred: the encoder pulls the pixels as it writes (measured 11% faster than rendering
        // first, and the files stay byte for byte as before).
        guard let cgImage = renderer.context.createCGImage(image, from: image.extent, format: format,
                                                            colorSpace: settings.colorSpace.cgColorSpace) else {
            throw ExportError("Rendering failed.")
        }

        var base = baseName ?? (detail.asset.filename as NSString).deletingPathExtension
        if baseName == nil, detail.asset.virtualCopyOf != nil, let copy = try catalog.virtualCopyName(of: assetID) {
            base += "-\(copy.replacingOccurrences(of: " ", with: ""))"
        }
        let target = Self.claimUniqueURL(in: settings.destination, base: base, extension: settings.format.fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, settings.format.type.identifier as CFString,
                                                                1, nil) else {
            try? FileManager.default.removeItem(at: target)
            throw ExportError("\(settings.format.label) export isn't supported on this Mac.")
        }
        let properties = Self.properties(source: source, detail: detail, settings: settings,
                                         width: cgImage.width, height: cgImage.height)
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: target)
            throw ExportError("The file could not be written.")
        }
        return target
    }

    /// `uniqueURL`, created empty at once so a photo exported alongside can't take the same name.
    static func claimUniqueURL(in folder: URL, base: String, extension ext: String) -> URL {
        var counter = 1
        while true {
            let name = counter == 1 ? base : "\(base) (\(counter))"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            let file = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if file >= 0 {
                close(file)
                return candidate
            }
            // Taken: try the next name. Any other error shows when the file is written.
            guard errno == EEXIST else { return candidate }
            counter += 1
        }
    }

    /// `name.jpg`, then `name (2).jpg`, and so on; existing files are never overwritten.
    static func uniqueURL(in folder: URL, base: String, extension ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    static func properties(source: URL, detail: AssetDetail, settings: ExportSettings,
                           width: Int, height: Int) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if settings.format.hasQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }
        guard settings.metadata != .none else { return properties }

        if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            var keys: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                                    kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
            if settings.metadata == .all { keys.append(kCGImagePropertyGPSDictionary) }
            for key in keys { if let value = original[key] { properties[key] = value } }
        }

        // Pixels are already upright and resized.
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "Atelier"
        properties[kCGImagePropertyTIFFDictionary] = tiff
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = width
        exif[kCGImagePropertyExifPixelYDimension] = height
        properties[kCGImagePropertyExifDictionary] = exif

        // Catalog values win over what the camera wrote.
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if !detail.keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = detail.keywords }
        if let title = detail.metadata.title { iptc[kCGImagePropertyIPTCObjectName] = title }
        if let caption = detail.metadata.caption {
            iptc[kCGImagePropertyIPTCCaptionAbstract] = caption
            tiff[kCGImagePropertyTIFFImageDescription] = caption
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if detail.metadata.rating > 0 { iptc[kCGImagePropertyIPTCStarRating] = detail.metadata.rating }
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary] = iptc }
        return properties
    }
}

public struct ExportError: LocalizedError {
    let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
