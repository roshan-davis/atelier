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
    public var texture: Double = 0
    public var clarity: Double = 0
    public var dehaze: Double = 0
    public var vibrance: Double = 0
    public var saturation: Double = 0

    // Detail
    /// Sharpening amount, 0...150.
    public var sharpening: Double = 0
    /// Sharpening radius in pixels of the full-size photo, 0.5...3.
    public var sharpenRadius: Double = 1
    /// 0...100.
    public var luminanceNoise: Double = 0
    /// 0...100.
    public var colorNoise: Double = 0

    // Effects
    /// Post-crop vignette: negative darkens the corners, positive lightens them.
    public var vignette: Double = 0
    /// 0...100; lower values reach further into the photo.
    public var vignetteMidpoint: Double = 50
    /// 0...100.
    public var grain: Double = 0
    /// 0...100.
    public var grainSize: Double = 25

    public init() {}

    /// Missing keys fall back to defaults, so older documents keep loading as fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DevelopSettings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        for parameter in Parameter.allCases where parameter != .temperature {
            if let key = CodingKeys(stringValue: parameter.rawValue),
               let value = try c.decodeIfPresent(Double.self, forKey: key) {
                self[parameter] = value
            } else {
                self[parameter] = defaults[parameter]
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, temperature, tint, exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, vibrance, saturation
        case sharpening, sharpenRadius, luminanceNoise, colorNoise
        case vignette, vignetteMidpoint, grain, grainSize
    }

    public static let neutral = DevelopSettings()

    public var isNeutral: Bool { self == .neutral }

    /// The Develop panels, in Lightroom's order.
    public enum Panel: String, CaseIterable, Sendable {
        case basic, detail, effects

        public var title: String {
            switch self {
            case .basic: return "Basic"
            case .detail: return "Detail"
            case .effects: return "Effects"
            }
        }

        public var parameters: [Parameter] { Parameter.allCases.filter { $0.panel == self } }
    }

    /// Names and ranges for the panels, in display order.
    public enum Parameter: String, CaseIterable, Sendable, Codable {
        case temperature, tint
        case exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, vibrance, saturation
        case sharpening, sharpenRadius, luminanceNoise, colorNoise
        case vignette, vignetteMidpoint, grain, grainSize

        public var range: ClosedRange<Double> {
            switch self {
            case .temperature: return 2000...50000
            case .tint: return -150...150
            case .exposure: return -5...5
            case .sharpening: return 0...150
            case .sharpenRadius: return 0.5...3
            case .luminanceNoise, .colorNoise, .vignetteMidpoint, .grain, .grainSize: return 0...100
            default: return -100...100
            }
        }

        public var label: String {
            switch self {
            case .temperature: return "Temp"
            case .sharpening, .vignette, .grain: return "Amount"
            case .sharpenRadius: return "Radius"
            case .luminanceNoise: return "Luminance"
            case .colorNoise: return "Color"
            case .vignetteMidpoint: return "Midpoint"
            case .grainSize: return "Size"
            default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }

        public var panel: Panel {
            switch self {
            case .sharpening, .sharpenRadius, .luminanceNoise, .colorNoise: return .detail
            case .vignette, .vignetteMidpoint, .grain, .grainSize: return .effects
            default: return .basic
            }
        }

        /// Sub-heading inside the panel.
        public var group: String {
            switch self {
            case .temperature, .tint: return "White Balance"
            case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: return "Tone"
            case .texture, .clarity, .dehaze, .vibrance, .saturation: return "Presence"
            case .sharpening, .sharpenRadius: return "Sharpening"
            case .luminanceNoise, .colorNoise: return "Noise Reduction"
            case .vignette, .vignetteMidpoint: return "Post-Crop Vignetting"
            case .grain, .grainSize: return "Grain"
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
            case .texture: return texture
            case .clarity: return clarity
            case .dehaze: return dehaze
            case .vibrance: return vibrance
            case .saturation: return saturation
            case .sharpening: return sharpening
            case .sharpenRadius: return sharpenRadius
            case .luminanceNoise: return luminanceNoise
            case .colorNoise: return colorNoise
            case .vignette: return vignette
            case .vignetteMidpoint: return vignetteMidpoint
            case .grain: return grain
            case .grainSize: return grainSize
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
            case .texture: texture = value
            case .clarity: clarity = value
            case .dehaze: dehaze = value
            case .vibrance: vibrance = value
            case .saturation: saturation = value
            case .sharpening: sharpening = value
            case .sharpenRadius: sharpenRadius = value
            case .luminanceNoise: luminanceNoise = value
            case .colorNoise: colorNoise = value
            case .vignette: vignette = value
            case .vignetteMidpoint: vignetteMidpoint = value
            case .grain: grain = value
            case .grainSize: grainSize = value
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
