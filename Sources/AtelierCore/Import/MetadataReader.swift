import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PhotoMetadata: Sendable, Hashable {
    public var captureTime: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var width: Int?
    public var height: Int?
    public var orientation: Int?
    public var uti: String?
    public var latitude: Double?
    public var longitude: Double?
    /// Embedded XMP, overridden by a sidecar when one exists.
    public var xmp = XMPFields()
}

/// Reads EXIF, TIFF, GPS and XMP through ImageIO. Exiv2 for formats ImageIO misses comes later.
public enum MetadataReader {
    public static func isSupported(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        // Skip hidden files and the AppleDouble "._" files SMB shares are full of.
        guard !name.hasPrefix(".") else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// `sidecarFor` is the file whose XMP sidecar applies, when `url` is a copy made elsewhere
    /// (the import's staged copy of a file on the NAS).
    public static func read(_ url: URL, sidecarFor: URL? = nil) -> PhotoMetadata {
        var result = PhotoMetadata()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, options) {
            result.uti = CGImageSourceGetType(source) as String?
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] ?? [:]
            result.width = properties[kCGImagePropertyPixelWidth] as? Int
            result.height = properties[kCGImagePropertyPixelHeight] as? Int
            result.orientation = properties[kCGImagePropertyOrientation] as? Int

            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            result.captureTime = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
                .flatMap(parseExifDate)
                ?? (tiff[kCGImagePropertyTIFFDateTime] as? String).flatMap(parseExifDate)
            result.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed
            result.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed
            result.lens = ((exif[kCGImagePropertyExifLensModel] as? String)
                ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String))?.trimmed

            if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
                let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
                result.latitude = latRef == "S" ? -lat : lat
                result.longitude = lonRef == "W" ? -lon : lon
            }
            if let embedded = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                result.xmp = XMPSidecar.fields(from: embedded)
            }
        }
        // Notes (AT-058) are kept per file name in the sidecar Atelier writes.
        let original = sidecarFor ?? url
        if let sidecar = XMPSidecar.read(sidecar: XMPSidecar.sidecarURL(for: original),
                                         filename: original.lastPathComponent) {
            result.xmp = sidecar
        }
        return result
    }

    /// EXIF dates have no time zone ("2026:10:25 14:03:11"); they are camera local time.
    static func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(string.prefix(19)))
    }
}

extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return value.isEmpty ? nil : value
    }
}
