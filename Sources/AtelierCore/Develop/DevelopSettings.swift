import Foundation

/// Non-destructive develop parameters: a versioned JSON document the renderer reads directly.
/// Nothing is baked into a file until export or Edit In.
///
/// Slider values use Lightroom's ranges so they feel familiar: -100...100 unless noted.
public struct DevelopSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = DevelopSettings.currentSchemaVersion

    // White balance. nil temperature means "as shot".
    /// Kelvin, 2000...50000.
    public var temperature: Double?
    /// -150...150, green to magenta.
    public var tint: Double = 0

    // Tone
    /// Stops, -5...5.
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0

    // Presence
    public var vibrance: Double = 0
    public var saturation: Double = 0

    public init() {}

    /// Missing keys fall back to defaults, so older documents keep loading as fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, temperature, tint, exposure, contrast, highlights, shadows, whites, blacks
        case vibrance, saturation
    }

    public static let neutral = DevelopSettings()

    public var isNeutral: Bool { self == .neutral }

    /// Names and ranges for the Basic panel, in display order.
    public enum Parameter: String, CaseIterable, Sendable, Codable {
        case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, vibrance, saturation

        public var range: ClosedRange<Double> {
            switch self {
            case .temperature: return 2000...50000
            case .tint: return -150...150
            case .exposure: return -5...5
            default: return -100...100
            }
        }

        public var label: String {
            rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }

        public var group: String {
            switch self {
            case .temperature, .tint: return "White Balance"
            case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: return "Tone"
            case .vibrance, .saturation: return "Presence"
            }
        }
    }

    public subscript(parameter: Parameter) -> Double {
        get {
            switch parameter {
            case .temperature: return temperature ?? 5500
            case .tint: return tint
            case .exposure: return exposure
            case .contrast: return contrast
            case .highlights: return highlights
            case .shadows: return shadows
            case .whites: return whites
            case .blacks: return blacks
            case .vibrance: return vibrance
            case .saturation: return saturation
            }
        }
        set {
            let value = min(max(newValue, parameter.range.lowerBound), parameter.range.upperBound)
            switch parameter {
            case .temperature: temperature = value
            case .tint: tint = value
            case .exposure: exposure = value
            case .contrast: contrast = value
            case .highlights: highlights = value
            case .shadows: shadows = value
            case .whites: whites = value
            case .blacks: blacks = value
            case .vibrance: vibrance = value
            case .saturation: saturation = value
            }
        }
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decoded(from json: String) throws -> DevelopSettings {
        try JSONDecoder().decode(DevelopSettings.self, from: Data(json.utf8))
    }
}
