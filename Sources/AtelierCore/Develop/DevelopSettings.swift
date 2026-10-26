import Foundation

/// Non-destructive develop parameters: a versioned JSON document the renderer reads directly.
/// Nothing is baked into a file until export or Edit In.
///
/// Slider values use Lightroom's ranges so they feel familiar: -100...100 unless noted.
/// Values are stored sparsely; anything left at its default is omitted, so two settings that
/// look the same compare equal.
public struct DevelopSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion = DevelopSettings.currentSchemaVersion

    /// White balance in Kelvin, 2000...50000. nil means "as shot".
    public var temperature: Double?

    private var values: [Parameter: Double] = [:]

    /// Point curves by channel, applied after the Basic tone and region curve. Each list runs
    /// from x 0 to 1 with at least two points; a missing channel is a straight line.
    private var pointCurves: [String: [CurvePoint]] = [:]

    public init() {}

    public func points(for channel: CurveChannel) -> [CurvePoint] {
        pointCurves[channel.rawValue] ?? CurvePoint.identity
    }

    public mutating func setPoints(_ points: [CurvePoint], for channel: CurveChannel) {
        // The spline needs strictly increasing x.
        var sorted: [CurvePoint] = []
        for point in points.sorted(by: { $0.x < $1.x }) where sorted.last.map({ point.x - $0.x > 0.005 }) ?? true {
            sorted.append(point)
        }
        pointCurves[channel.rawValue] = sorted.count < 2 || sorted == CurvePoint.identity ? nil : sorted
    }

    public var hasPointCurve: Bool { !pointCurves.isEmpty }

    public var tint: Double {
        get { self[.tint] }
        set { self[.tint] = newValue }
    }
    public var exposure: Double {
        get { self[.exposure] }
        set { self[.exposure] = newValue }
    }
    public var contrast: Double {
        get { self[.contrast] }
        set { self[.contrast] = newValue }
    }
    public var highlights: Double {
        get { self[.highlights] }
        set { self[.highlights] = newValue }
    }
    public var shadows: Double {
        get { self[.shadows] }
        set { self[.shadows] = newValue }
    }
    public var whites: Double {
        get { self[.whites] }
        set { self[.whites] = newValue }
    }
    public var blacks: Double {
        get { self[.blacks] }
        set { self[.blacks] = newValue }
    }
    public var texture: Double {
        get { self[.texture] }
        set { self[.texture] = newValue }
    }
    public var clarity: Double {
        get { self[.clarity] }
        set { self[.clarity] = newValue }
    }
    public var dehaze: Double {
        get { self[.dehaze] }
        set { self[.dehaze] = newValue }
    }
    public var vibrance: Double {
        get { self[.vibrance] }
        set { self[.vibrance] = newValue }
    }
    public var saturation: Double {
        get { self[.saturation] }
        set { self[.saturation] = newValue }
    }
    public var sharpening: Double {
        get { self[.sharpening] }
        set { self[.sharpening] = newValue }
    }
    public var sharpenRadius: Double {
        get { self[.sharpenRadius] }
        set { self[.sharpenRadius] = newValue }
    }
    public var luminanceNoise: Double {
        get { self[.luminanceNoise] }
        set { self[.luminanceNoise] = newValue }
    }
    public var colorNoise: Double {
        get { self[.colorNoise] }
        set { self[.colorNoise] = newValue }
    }
    public var vignette: Double {
        get { self[.vignette] }
        set { self[.vignette] = newValue }
    }
    public var vignetteMidpoint: Double {
        get { self[.vignetteMidpoint] }
        set { self[.vignetteMidpoint] = newValue }
    }
    public var grain: Double {
        get { self[.grain] }
        set { self[.grain] = newValue }
    }
    public var grainSize: Double {
        get { self[.grainSize] }
        set { self[.grainSize] = newValue }
    }

    public subscript(parameter: Parameter) -> Double {
        get {
            if parameter == .temperature { return temperature ?? 5500 }
            return values[parameter] ?? parameter.defaultValue
        }
        set {
            let value = min(max(newValue, parameter.range.lowerBound), parameter.range.upperBound)
            if parameter == .temperature {
                temperature = value
            } else if value == parameter.defaultValue {
                values[parameter] = nil
            } else {
                values[parameter] = value
            }
        }
    }

    // MARK: Coding

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Missing keys fall back to defaults, so older documents keep loading as fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        // Older documents are upgraded in memory; new fields take their defaults.
        _ = try c.decodeIfPresent(Int.self, forKey: Key("schemaVersion"))
        schemaVersion = Self.currentSchemaVersion
        temperature = try c.decodeIfPresent(Double.self, forKey: Key("temperature"))
        for parameter in Parameter.allCases where parameter != .temperature {
            if let value = try c.decodeIfPresent(Double.self, forKey: Key(parameter.rawValue)) {
                self[parameter] = value
            }
        }
        let curves = try c.decodeIfPresent([String: [CurvePoint]].self, forKey: Key("pointCurves")) ?? [:]
        for channel in CurveChannel.allCases {
            if let points = curves[channel.rawValue] { setPoints(points, for: channel) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(schemaVersion, forKey: Key("schemaVersion"))
        try c.encodeIfPresent(temperature, forKey: Key("temperature"))
        for (parameter, value) in values {
            try c.encode(value, forKey: Key(parameter.rawValue))
        }
        if !pointCurves.isEmpty { try c.encode(pointCurves, forKey: Key("pointCurves")) }
    }

    public static let neutral = DevelopSettings()

    public var isNeutral: Bool { temperature == nil && values.isEmpty && pointCurves.isEmpty }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decoded(from json: String) throws -> DevelopSettings {
        try JSONDecoder().decode(DevelopSettings.self, from: Data(json.utf8))
    }

    // MARK: Panels and parameters

    public enum CurveChannel: String, CaseIterable, Sendable {
        case rgb, red, green, blue

        public var label: String { self == .rgb ? "RGB" : rawValue.capitalized }
    }

    public struct CurvePoint: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = min(1, max(0, x))
            self.y = min(1, max(0, y))
        }

        public static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    /// The Develop panels, in Lightroom's order.
    public enum Panel: String, CaseIterable, Sendable {
        case basic, toneCurve, hsl, colorGrading, detail, effects

        public var title: String {
            switch self {
            case .basic: return "Basic"
            case .toneCurve: return "Tone Curve"
            case .hsl: return "HSL / Color"
            case .colorGrading: return "Color Grading"
            case .detail: return "Detail"
            case .effects: return "Effects"
            }
        }

        public var parameters: [Parameter] { Parameter.allCases.filter { $0.panel == self } }
    }

    /// The eight HSL color bands.
    public enum ColorBand: String, CaseIterable, Sendable {
        case red = "Red", orange = "Orange", yellow = "Yellow", green = "Green"
        case aqua = "Aqua", blue = "Blue", purple = "Purple", magenta = "Magenta"

        /// Band center on the hue circle, in degrees.
        public var hue: Double {
            switch self {
            case .red: return 0
            case .orange: return 30
            case .yellow: return 60
            case .green: return 120
            case .aqua: return 180
            case .blue: return 240
            case .purple: return 270
            case .magenta: return 300
            }
        }
    }

    public enum HSLChannel: String, CaseIterable, Sendable {
        case hue = "Hue", saturation = "Saturation", luminance = "Luminance"

        var prefix: String {
            switch self {
            case .hue: return "hue"
            case .saturation: return "sat"
            case .luminance: return "lum"
            }
        }
    }

    /// The color grading wheels.
    public enum GradeRegion: String, CaseIterable, Sendable {
        case shadows = "Shadows", midtones = "Midtones", highlights = "Highlights", global = "Global"

        public var hue: Parameter { Parameter(rawValue: "grade\(rawValue)Hue")! }
        public var saturation: Parameter { Parameter(rawValue: "grade\(rawValue)Sat")! }
        public var luminance: Parameter { Parameter(rawValue: "grade\(rawValue)Lum")! }
    }

    public enum Parameter: String, CaseIterable, Sendable, Codable {
        case temperature, tint
        case exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, vibrance, saturation
        case curveHighlights, curveLights, curveDarks, curveShadows
        case hueRed
        case hueOrange
        case hueYellow
        case hueGreen
        case hueAqua
        case hueBlue
        case huePurple
        case hueMagenta
        case satRed
        case satOrange
        case satYellow
        case satGreen
        case satAqua
        case satBlue
        case satPurple
        case satMagenta
        case lumRed
        case lumOrange
        case lumYellow
        case lumGreen
        case lumAqua
        case lumBlue
        case lumPurple
        case lumMagenta
        case gradeShadowsHue, gradeShadowsSat, gradeShadowsLum
        case gradeMidtonesHue, gradeMidtonesSat, gradeMidtonesLum
        case gradeHighlightsHue, gradeHighlightsSat, gradeHighlightsLum
        case gradeGlobalHue, gradeGlobalSat, gradeGlobalLum
        case gradeBlending, gradeBalance
        case sharpening, sharpenRadius, luminanceNoise, colorNoise
        case vignette, vignetteMidpoint, grain, grainSize

        public static func hsl(_ channel: HSLChannel, _ band: ColorBand) -> Parameter {
            Parameter(rawValue: channel.prefix + band.rawValue)!
        }

        /// The band and channel of an HSL parameter.
        public var hslBand: (HSLChannel, ColorBand)? {
            for channel in HSLChannel.allCases where rawValue.hasPrefix(channel.prefix) {
                if let band = ColorBand(rawValue: String(rawValue.dropFirst(3))) { return (channel, band) }
            }
            return nil
        }

        public var defaultValue: Double {
            switch self {
            case .temperature: return 5500
            case .sharpenRadius: return 1
            case .vignetteMidpoint, .gradeBlending: return 50
            case .grainSize: return 25
            default: return 0
            }
        }

        public var range: ClosedRange<Double> {
            switch self {
            case .temperature: return 2000...50000
            case .tint: return -150...150
            case .exposure: return -5...5
            case .sharpening: return 0...150
            case .sharpenRadius: return 0.5...3
            case .luminanceNoise, .colorNoise, .vignetteMidpoint, .grain, .grainSize, .gradeBlending: return 0...100
            case .gradeShadowsHue, .gradeMidtonesHue, .gradeHighlightsHue, .gradeGlobalHue: return 0...360
            case .gradeShadowsSat, .gradeMidtonesSat, .gradeHighlightsSat, .gradeGlobalSat: return 0...100
            default: return -100...100
            }
        }

        public var label: String {
            if let band = hslBand?.1 { return band.rawValue }
            switch self {
            case .temperature: return "Temp"
            case .sharpening, .vignette, .grain: return "Amount"
            case .sharpenRadius: return "Radius"
            case .luminanceNoise: return "Luminance"
            case .colorNoise: return "Color"
            case .vignetteMidpoint: return "Midpoint"
            case .grainSize: return "Size"
            case .curveHighlights: return "Highlights"
            case .curveLights: return "Lights"
            case .curveDarks: return "Darks"
            case .curveShadows: return "Shadows"
            case .gradeBlending: return "Blending"
            case .gradeBalance: return "Balance"
            default:
                if rawValue.hasPrefix("grade") {
                    if rawValue.hasSuffix("Hue") { return "Hue" }
                    if rawValue.hasSuffix("Sat") { return "Saturation" }
                    return "Luminance"
                }
                return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }

        public var panel: Panel {
            if hslBand != nil { return .hsl }
            if rawValue.hasPrefix("grade") { return .colorGrading }
            if rawValue.hasPrefix("curve") { return .toneCurve }
            switch self {
            case .sharpening, .sharpenRadius, .luminanceNoise, .colorNoise: return .detail
            case .vignette, .vignetteMidpoint, .grain, .grainSize: return .effects
            default: return .basic
            }
        }

        /// Sub-heading inside the panel.
        public var group: String {
            if let channel = hslBand?.0 { return channel.rawValue }
            switch self {
            case .temperature, .tint: return "White Balance"
            case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: return "Tone"
            case .texture, .clarity, .dehaze, .vibrance, .saturation: return "Presence"
            case .curveHighlights, .curveLights, .curveDarks, .curveShadows: return "Region"
            case .sharpening, .sharpenRadius: return "Sharpening"
            case .luminanceNoise, .colorNoise: return "Noise Reduction"
            case .vignette, .vignetteMidpoint: return "Post-Crop Vignetting"
            case .grain, .grainSize: return "Grain"
            case .gradeBlending, .gradeBalance: return "Blend"
            default:
                return GradeRegion.allCases.first { rawValue.hasPrefix("grade\($0.rawValue)") }?.rawValue ?? ""
            }
        }
    }
}
