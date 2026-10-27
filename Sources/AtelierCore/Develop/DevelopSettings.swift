import Foundation
import CoreGraphics

/// Non-destructive develop parameters: a versioned JSON document the renderer reads directly.
/// Nothing is baked into a file until export or Edit In.
///
/// Slider values use Lightroom's ranges so they feel familiar: -100...100 unless noted.
/// Values are stored sparsely; anything left at its default is omitted, so two settings that
/// look the same compare equal.
public struct DevelopSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion = DevelopSettings.currentSchemaVersion

    /// White balance in Kelvin, 2000...50000. nil means "as shot".
    public var temperature: Double?

    private var values: [Parameter: Double] = [:]

    /// Point curves by channel, applied after the Basic tone and region curve. Each list runs
    /// from x 0 to 1 with at least two points; a missing channel is a straight line.
    private var pointCurves: [String: [CurvePoint]] = [:]

    /// Crop, straighten, rotation and flips; nil when the photo is uncropped and upright.
    public var crop: Crop? {
        get { storedCrop }
        set { storedCrop = newValue?.isIdentity == true ? nil : newValue }
    }
    private var storedCrop: Crop?

    /// Local adjustments, applied in order after the global ones (see Masks.swift).
    public var masks: [Mask] = []

    /// Basic > Profile: the base look under every slider (RAW files).
    public var profile = Profile.cameraMatching
    /// Lens Corrections > Enable Profile Corrections: the RAW engine's corrections for the lens.
    public var lensProfileCorrections = true
    /// Transform > Upright; nil is Off.
    public var upright: Upright?
    /// Transform > Constrain Crop: enlarge the corrected photo so no empty edges show.
    public var constrainCrop = false

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
        crop = try c.decodeIfPresent(Crop.self, forKey: Key("crop"))
        // A mask this version can't read never costs the photo its other settings.
        masks = (try? c.decodeIfPresent([Mask].self, forKey: Key("masks"))) ?? []
        profile = (try? c.decodeIfPresent(Profile.self, forKey: Key("profile"))) ?? .cameraMatching
        lensProfileCorrections = try c.decodeIfPresent(Bool.self, forKey: Key("lensProfileCorrections")) ?? true
        upright = try? c.decodeIfPresent(Upright.self, forKey: Key("upright"))
        constrainCrop = try c.decodeIfPresent(Bool.self, forKey: Key("constrainCrop")) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(schemaVersion, forKey: Key("schemaVersion"))
        try c.encodeIfPresent(temperature, forKey: Key("temperature"))
        for (parameter, value) in values {
            try c.encode(value, forKey: Key(parameter.rawValue))
        }
        if !pointCurves.isEmpty { try c.encode(pointCurves, forKey: Key("pointCurves")) }
        try c.encodeIfPresent(storedCrop, forKey: Key("crop"))
        if !masks.isEmpty { try c.encode(masks, forKey: Key("masks")) }
        if profile != .cameraMatching { try c.encode(profile, forKey: Key("profile")) }
        if !lensProfileCorrections { try c.encode(false, forKey: Key("lensProfileCorrections")) }
        try c.encodeIfPresent(upright, forKey: Key("upright"))
        if constrainCrop { try c.encode(true, forKey: Key("constrainCrop")) }
    }

    public static let neutral = DevelopSettings()

    public var isNeutral: Bool {
        temperature == nil && values.isEmpty && pointCurves.isEmpty && storedCrop == nil && masks.isEmpty
            && profile == .cameraMatching && lensProfileCorrections && upright == nil && !constrainCrop
    }

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
        case basic, toneCurve, hsl, colorGrading, detail, lensCorrections, transform, effects

        public var title: String {
            switch self {
            case .basic: return "Basic"
            case .toneCurve: return "Tone Curve"
            case .hsl: return "HSL / Color"
            case .colorGrading: return "Color Grading"
            case .detail: return "Detail"
            case .lensCorrections: return "Lens Corrections"
            case .transform: return "Transform"
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
        case lensDistortion, lensVignette, lensVignetteMidpoint
        case transformVertical, transformHorizontal, transformRotate, transformAspect, transformScale
        case transformOffsetX, transformOffsetY
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
            case .vignetteMidpoint, .gradeBlending, .lensVignetteMidpoint: return 50
            case .transformScale: return 100
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
            case .luminanceNoise, .colorNoise, .vignetteMidpoint, .grain, .grainSize, .gradeBlending,
                 .lensVignetteMidpoint: return 0...100
            case .transformRotate: return -10...10
            case .transformScale: return 50...150
            case .gradeShadowsHue, .gradeMidtonesHue, .gradeHighlightsHue, .gradeGlobalHue: return 0...360
            case .gradeShadowsSat, .gradeMidtonesSat, .gradeHighlightsSat, .gradeGlobalSat: return 0...100
            default: return -100...100
            }
        }

        public var label: String {
            if let band = hslBand?.1 { return band.rawValue }
            switch self {
            case .temperature: return "Temp"
            case .sharpening, .vignette, .grain, .lensDistortion, .lensVignette: return "Amount"
            case .lensVignetteMidpoint: return "Midpoint"
            case .transformVertical: return "Vertical"
            case .transformHorizontal: return "Horizontal"
            case .transformRotate: return "Rotate"
            case .transformAspect: return "Aspect"
            case .transformScale: return "Scale"
            case .transformOffsetX: return "X Offset"
            case .transformOffsetY: return "Y Offset"
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
            if rawValue.hasPrefix("lens") { return .lensCorrections }
            if rawValue.hasPrefix("transform") { return .transform }
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
            case .lensDistortion: return "Distortion"
            case .lensVignette, .lensVignetteMidpoint: return "Vignetting"
            case .transformVertical, .transformHorizontal, .transformRotate, .transformAspect, .transformScale,
                 .transformOffsetX, .transformOffsetY: return "Transform"
            case .gradeBlending, .gradeBalance: return "Blend"
            default:
                return GradeRegion.allCases.first { rawValue.hasPrefix("grade\($0.rawValue)") }?.rawValue ?? ""
            }
        }
    }

    /// Geometry, applied before every other adjustment so the histogram, vignette and grain
    /// follow the crop (Lightroom's post-crop vignetting).
    ///
    /// The photo is first turned and flipped, then rotated by `angle` around its center, and
    /// then cut to `x, y, width, height`: fractions of the turned photo's width and height,
    /// measured from its top left in a frame that rotates with it, so straightening never
    /// moves the crop.
    public struct Crop: Codable, Hashable, Sendable {
        /// Quarter turns clockwise, 0...3.
        public var quarterTurns = 0
        public var flipHorizontal = false
        public var flipVertical = false
        /// Straighten angle in degrees, -45...45; positive turns the photo clockwise.
        public var angle = 0.0
        public var x = 0.0
        public var y = 0.0
        public var width = 1.0
        public var height = 1.0
        /// The aspect ratio (width / height, in pixels) the crop is locked to; nil is free.
        public var lockedAspect: Double?

        public init() {}

        public var isIdentity: Bool {
            quarterTurns % 4 == 0 && !flipHorizontal && !flipVertical && angle == 0
                && x == 0 && y == 0 && width == 1 && height == 1 && lockedAspect == nil
        }

        public var hasCut: Bool { x != 0 || y != 0 || width != 1 || height != 1 || angle != 0 }

        /// The turned photo's size, for a photo of `size` pixels.
        public func orientedSize(_ size: CGSize) -> CGSize {
            quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        }

        /// The cropped photo's size, for a photo of `size` pixels.
        public func outputSize(_ size: CGSize) -> CGSize {
            let oriented = orientedSize(size)
            return CGSize(width: (oriented.width * width).rounded(), height: (oriented.height * height).rounded())
        }

        /// Whether every corner of the crop lies on the photo once it is straightened.
        /// `imageAspect` is the turned photo's width / height.
        public func fits(imageAspect: Double) -> Bool {
            corners(imageAspect: imageAspect).allSatisfy { point in
                point.x >= -1e-6 && point.x <= imageAspect + 1e-6 && point.y >= -1e-6 && point.y <= 1 + 1e-6
            }
        }

        /// The crop's corners mapped back onto the unrotated photo, in units of its height.
        private func corners(imageAspect: Double) -> [CGPoint] {
            let w = imageAspect
            let center = CGPoint(x: w / 2, y: 0.5)
            let radians = angle * .pi / 180
            let cosA = cos(radians), sinA = sin(radians)
            let rect = [(x, y), (x + width, y), (x, y + height), (x + width, y + height)]
            return rect.map { corner in
                let dx = corner.0 * w - center.x, dy = corner.1 - center.y
                // Undo a clockwise turn (y points down).
                return CGPoint(x: center.x + dx * cosA + dy * sinA, y: center.y - dx * sinA + dy * cosA)
            }
        }

        /// The largest version of this crop, shrunk about its center (and moved toward the
        /// photo's center if needed), that stays on the straightened photo.
        public func fitted(imageAspect: Double) -> Crop {
            if fits(imageAspect: imageAspect) { return self }
            var moved = self
            if !moved.scaled(by: 0.001).fits(imageAspect: imageAspect) {
                // Slide the center toward the photo's center until a tiny crop fits there.
                var low = 0.0, high = 1.0
                let cx = x + width / 2, cy = y + height / 2
                for _ in 0..<30 {
                    let t = (low + high) / 2
                    var candidate = self
                    candidate.x = cx + (0.5 - cx) * t - width / 2
                    candidate.y = cy + (0.5 - cy) * t - height / 2
                    if candidate.scaled(by: 0.001).fits(imageAspect: imageAspect) { high = t } else { low = t }
                }
                moved.x = cx + (0.5 - cx) * high - width / 2
                moved.y = cy + (0.5 - cy) * high - height / 2
            }
            var low = 0.0, high = 1.0
            for _ in 0..<30 {
                let scale = (low + high) / 2
                if moved.scaled(by: scale).fits(imageAspect: imageAspect) { low = scale } else { high = scale }
            }
            return moved.scaled(by: low)
        }

        /// Scaled about its center.
        public func scaled(by factor: Double) -> Crop {
            var copy = self
            copy.width = width * factor
            copy.height = height * factor
            copy.x = x + (width - copy.width) / 2
            copy.y = y + (height - copy.height) / 2
            return copy
        }

        /// The largest crop of `aspect` (pixel width / height) centered on the photo.
        /// `imageAspect` is the turned photo's width / height.
        public static func centered(aspect: Double, imageAspect: Double) -> (width: Double, height: Double) {
            if aspect > imageAspect {
                return (1, imageAspect / aspect)
            }
            return (aspect / imageAspect, 1)
        }
    }
}
