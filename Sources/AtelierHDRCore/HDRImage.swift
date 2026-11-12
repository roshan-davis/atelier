import Foundation

/// Upright, white-balanced linear RGB. Values above display white are retained.
/// This is demosaiced RGB, not sensor mosaic data or newly captured scene detail.
public struct HDRImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgb: [Float]

    public init(width: Int, height: Int, rgb: [Float]) throws {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              width <= Int.max / height / 3, rgb.count == width * height * 3,
              rgb.allSatisfy({ $0.isFinite }) else { throw HDRError.invalidImage }
        self.width = width; self.height = height; self.rgb = rgb
    }
}

public enum HDRError: Error, LocalizedError {
    case invalidImage, invalidSettings, unsupportedImage, invalidProject(String)
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "The HDR image has invalid dimensions or pixel values."
        case .invalidSettings: return "The HDR settings are outside their supported range."
        case .unsupportedImage: return "This image could not be decoded for HDR processing."
        case .invalidProject(let reason): return "The HDR project could not be opened: \(reason)"
        }
    }
}

/// How the photo's range is brought into the screen's. The HDR panel's Method menu offers
/// Natural (`direct`) and Fusion (`fusion`); `virtualExposureFusion` is the older global
/// comparison baseline, kept for the qualification tool and never shown in the app.
public enum HDRMethod: String, Codable, CaseIterable, Sendable {
    case direct, virtualExposureFusion
    /// Three exposures of the photo (−spacing, 0, +spacing EV), blended region by region by how
    /// well exposed each region is in each (Rosh, Nov 12, 2026: show the photo at three exposures
    /// and merge them, as Machinery HDR's fusion modes do). With brackets the same blend will
    /// take the real frames.
    case fusion
}

/// Candidate controls for qualification. Zero texture adjustments preserve the base tone map.
public struct HDRSettings: Codable, Equatable, Sendable {
    public var method: HDRMethod = .direct
    public var toneEnabled = true
    public var artifactsEnabled = true
    public var exposure: Float = 0
    public var compression: Float = 0.65
    public var microcontrast: Float = 0.6
    public var detail: Float = 0.35
    public var shadowProtection: Float = 0.5
    public var highlightProtection: Float = 0.5
    /// Lightroom-style tone of the dark and bright regions after tone mapping, -1...1; 0 changes
    /// nothing (Rosh, Nov 12, 2026: the texture-protection sliders had no visible effect).
    public var shadows: Float = 0
    public var highlights: Float = 0
    /// Fusion's exposures are this many EV under and over the photo, 1...3. Only Fusion uses it.
    public var fusionSpacing: Float = 2
    /// Color after tone mapping, -1...1, 0 changes nothing (Rosh, Nov 12, 2026: presets need
    /// color to differ, as Machinery HDR's and Aurora's do). Temperature warms (+) or cools (−)
    /// at the same brightness; Vibrance raises muted colors more than saturated ones.
    public var temperature: Float = 0
    public var saturation: Float = 0
    public var vibrance: Float = 0
    public init() {}

    /// Whether any color control is away from 0.
    public var hasColor: Bool { temperature != 0 || saturation != 0 || vibrance != 0 }

    enum CodingKeys: String, CodingKey {
        case method, toneEnabled, artifactsEnabled, exposure, compression, microcontrast, detail, shadowProtection, highlightProtection
        case shadows, highlights, fusionSpacing, temperature, saturation, vibrance
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(HDRMethod.self, forKey: .method) ?? .direct
        toneEnabled = try c.decodeIfPresent(Bool.self, forKey: .toneEnabled) ?? true
        artifactsEnabled = try c.decodeIfPresent(Bool.self, forKey: .artifactsEnabled) ?? true
        exposure = try c.decodeIfPresent(Float.self, forKey: .exposure) ?? 0
        compression = try c.decodeIfPresent(Float.self, forKey: .compression) ?? 0.65
        microcontrast = try c.decodeIfPresent(Float.self, forKey: .microcontrast) ?? 0.6
        detail = try c.decodeIfPresent(Float.self, forKey: .detail) ?? 0.35
        shadowProtection = try c.decodeIfPresent(Float.self, forKey: .shadowProtection) ?? 0.5
        highlightProtection = try c.decodeIfPresent(Float.self, forKey: .highlightProtection) ?? 0.5
        shadows = try c.decodeIfPresent(Float.self, forKey: .shadows) ?? 0
        highlights = try c.decodeIfPresent(Float.self, forKey: .highlights) ?? 0
        fusionSpacing = try c.decodeIfPresent(Float.self, forKey: .fusionSpacing) ?? 2
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature) ?? 0
        saturation = try c.decodeIfPresent(Float.self, forKey: .saturation) ?? 0
        vibrance = try c.decodeIfPresent(Float.self, forKey: .vibrance) ?? 0
        try validate()
    }

    public func validate() throws {
        guard exposure.isFinite, (-5...5).contains(exposure),
              [compression, shadowProtection, highlightProtection].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [microcontrast, detail, shadows, highlights, temperature, saturation, vibrance]
                .allSatisfy({ $0.isFinite && (-1...1).contains($0) }),
              fusionSpacing.isFinite, (1...3).contains(fusionSpacing) else {
            throw HDRError.invalidSettings
        }
    }
}
