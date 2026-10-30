import Foundation
import ImageIO

/// How a photo was taken, from its EXIF: the line under the Develop histogram, as in Lightroom
/// ("ISO 400   50 mm   ƒ/2.8   1/250 sec"), and the camera, lens and exposure compensation for
/// its tooltip.
public struct ShootingInfo: Sendable, Hashable {
    public var iso: Double?
    /// Real focal length in mm, not the 35 mm equivalent.
    public var focalLength: Double?
    public var aperture: Double?
    /// Seconds.
    public var shutterSpeed: Double?
    /// Stops.
    public var exposureCompensation: Double?
    public var camera: String?
    public var lens: String?

    public init(iso: Double? = nil, focalLength: Double? = nil, aperture: Double? = nil, shutterSpeed: Double? = nil,
                exposureCompensation: Double? = nil, camera: String? = nil, lens: String? = nil) {
        self.iso = iso
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.exposureCompensation = exposureCompensation
        self.camera = camera
        self.lens = lens
    }

    /// Reads only the file's properties, not its pixels, so it is quick even for RAW files.
    public init(url: URL) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            self.init()
            return
        }
        self.init(properties: properties)
    }

    /// From ImageIO's properties dictionary.
    public init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func number(_ value: Any?) -> Double? {
            guard let value = (value as? NSNumber)?.doubleValue, value > 0, value.isFinite else { return nil }
            return value
        }
        let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
        iso = number(isoValues?.first) ?? number(exif[kCGImagePropertyExifRecommendedExposureIndex])
        focalLength = number(exif[kCGImagePropertyExifFocalLength])
        aperture = number(exif[kCGImagePropertyExifFNumber])
            // APEX aperture value: f-number = 2^(Av/2).
            ?? number(exif[kCGImagePropertyExifApertureValue]).map { pow(2, $0 / 2) }
        shutterSpeed = number(exif[kCGImagePropertyExifExposureTime])
        exposureCompensation = (exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        camera = Self.cameraName(make: make, model: model)
        lens = ((exif[kCGImagePropertyExifLensModel] as? String)
            ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String))?
            .trimmingCharacters(in: .whitespaces)
        if lens?.isEmpty == true { lens = nil }
    }

    /// "NIKON CORPORATION" + "NIKON Z f" reads "NIKON Z f": the make is left out when the model
    /// already starts with its first word, as most cameras' models do.
    static func cameraName(make: String?, model: String?) -> String? {
        guard let model, !model.isEmpty else { return make?.isEmpty == false ? make : nil }
        guard let make, !make.isEmpty,
              let brand = make.split(separator: " ").first,
              !model.lowercased().hasPrefix(brand.lowercased()) else { return model }
        return "\(make) \(model)"
    }

    /// Nothing to show: a scan, a screenshot, or an export that dropped its EXIF.
    public var isEmpty: Bool { iso == nil && focalLength == nil && aperture == nil && shutterSpeed == nil }

    /// The histogram's line, in Lightroom's order: ISO, focal length, aperture, shutter speed.
    public var parts: [String] {
        [iso.map(Self.formatISO), focalLength.map(Self.formatFocalLength),
         aperture.map(Self.formatAperture), shutterSpeed.map(Self.formatShutterSpeed)].compactMap { $0 }
    }

    /// Camera, lens and exposure compensation, one per line, for the tooltip.
    public var details: String {
        var lines: [String] = []
        if let camera { lines.append(camera) }
        if let lens { lines.append(lens) }
        if let exposureCompensation { lines.append("Exposure compensation " + Self.formatExposureCompensation(exposureCompensation)) }
        return lines.joined(separator: "\n")
    }

    public static func formatISO(_ iso: Double) -> String {
        "ISO \(Int(iso.rounded()))"
    }

    /// "50 mm", "24.5 mm".
    public static func formatFocalLength(_ mm: Double) -> String {
        "\(trimmed(mm)) mm"
    }

    /// "ƒ/2.8", "ƒ/8".
    public static func formatAperture(_ fNumber: Double) -> String {
        "ƒ/\(trimmed(fNumber))"
    }

    /// "1/250 sec" below a second when the camera's speed is a whole fraction, as almost every
    /// speed is; otherwise seconds: "0.6 sec", "1 sec", "2.5 sec", "30 sec".
    public static func formatShutterSpeed(_ seconds: Double) -> String {
        if seconds < 1 {
            let denominator = 1 / seconds
            let whole = denominator.rounded()
            // Cameras store 1/250 as 0.004 or 10/2500, so allow a little rounding.
            if whole >= 2, abs(denominator - whole) / denominator < 0.02 { return "1/\(Int(whole)) sec" }
            if seconds < 0.1 { return "1/\(Int(denominator.rounded())) sec" }
        }
        return "\(trimmed(seconds)) sec"
    }

    /// "+0.7 EV", "−1 EV", "0 EV".
    public static func formatExposureCompensation(_ stops: Double) -> String {
        let rounded = (stops * 100).rounded() / 100
        if rounded == 0 { return "0 EV" }
        return (rounded > 0 ? "+" : "−") + trimmed(abs(rounded)) + " EV"
    }

    /// One decimal at most, and none when it would be ".0".
    private static func trimmed(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? "\(Int(tenths))" : String(format: "%.1f", tenths)
    }
}
