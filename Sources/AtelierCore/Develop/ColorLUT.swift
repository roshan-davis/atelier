import Foundation

/// Builds the color cube for the HSL / Color and Color Grading panels. Both are per-pixel color
/// mappings, so one 3D lookup table applies them together on the GPU.
enum ColorLUT {
    static let dimension = 32

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedKey: [Double]?
    nonisolated(unsafe) private static var cachedCube: Data?

    /// The parameters the cube depends on, in a fixed order.
    private static let parameters: [DevelopSettings.Parameter] = DevelopSettings.Parameter.allCases
        .filter { $0.panel == .hsl || $0.panel == .colorGrading }

    /// RGBA float cube data, or nil when both panels are at their defaults and the photo is in color.
    static func cube(for settings: DevelopSettings) -> Data? {
        let key = parameters.map { settings[$0] } + [settings.monochrome ? 1 : 0]
        let neutral = parameters.map { $0.defaultValue } + [0]
        guard key != neutral else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if key == cachedKey, let cachedCube { return cachedCube }
        let hsl = HSLAdjustment(settings), bw = settings.monochrome ? BWMix(settings) : nil, grade = ColorGrade(settings)
        // In Black & White, the B&W Mix replaces HSL; color grading then tones the grays.
        let cube = build { color in
            var rgb = color
            if let bw {
                rgb = bw.apply(rgb)
            } else if hsl.isActive {
                rgb = hsl.apply(rgb)
            }
            return grade.isActive ? grade.apply(rgb) : rgb
        }
        cachedKey = key
        cachedCube = cube
        return cube
    }

    /// Color Grading Balance's Option-drag view: the colors after HSL, mapped to the color of the
    /// tonal range each falls in (see `ColorGrade.regionMap`).
    static func regionMapCube(for settings: DevelopSettings) -> Data {
        let hsl = HSLAdjustment(settings), bw = settings.monochrome ? BWMix(settings) : nil, grade = ColorGrade(settings)
        return build { color in
            var rgb = color
            if let bw {
                rgb = bw.apply(rgb)
            } else if hsl.isActive {
                rgb = hsl.apply(rgb)
            }
            return grade.regionMap(rgb)
        }
    }

    private static func build(_ map: (RGB) -> RGB) -> Data {
        let n = dimension
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        // Core Image cubes vary red fastest, then green, then blue.
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rgb = map((Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1)))
                    values[index] = Float(min(1, max(0, rgb.0)))
                    values[index + 1] = Float(min(1, max(0, rgb.1)))
                    values[index + 2] = Float(min(1, max(0, rgb.2)))
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

typealias RGB = (Double, Double, Double)

func luma(_ c: RGB) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }

/// Hue in degrees 0..<360, saturation and lightness 0...1.
func rgbToHSL(_ c: RGB) -> (h: Double, s: Double, l: Double) {
    let maxV = max(c.0, c.1, c.2), minV = min(c.0, c.1, c.2)
    let l = (maxV + minV) / 2
    let d = maxV - minV
    guard d > 1e-6 else { return (0, 0, l) }
    let s = d / (1 - abs(2 * l - 1))
    var h: Double
    if maxV == c.0 {
        h = ((c.1 - c.2) / d).truncatingRemainder(dividingBy: 6)
    } else if maxV == c.1 {
        h = (c.2 - c.0) / d + 2
    } else {
        h = (c.0 - c.1) / d + 4
    }
    h *= 60
    if h < 0 { h += 360 }
    return (h, min(1, s), l)
}

func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> RGB {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let m = l - c / 2
    let rgb: RGB
    switch hp {
    case 0..<1: rgb = (c, x, 0)
    case 1..<2: rgb = (x, c, 0)
    case 2..<3: rgb = (0, c, x)
    case 3..<4: rgb = (0, x, c)
    case 4..<5: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
}

/// Lightroom-style HSL: eight overlapping hue bands, each shifting hue, scaling saturation and
/// raising or lowering luminance of the colors it covers. Grays are never touched.
struct HSLAdjustment {
    typealias Band = DevelopSettings.ColorBand
    private let hue: [Double]
    private let saturation: [Double]
    private let luminance: [Double]
    let isActive: Bool

    init(_ settings: DevelopSettings) {
        hue = Band.allCases.map { settings[.hsl(.hue, $0)] / 100 }
        saturation = Band.allCases.map { settings[.hsl(.saturation, $0)] / 100 }
        luminance = Band.allCases.map { settings[.hsl(.luminance, $0)] / 100 }
        isActive = (hue + saturation + luminance).contains { $0 != 0 }
    }

    /// Weights of the eight bands for a hue: linear between neighboring band centers, so they
    /// always sum to 1.
    static func weights(for h: Double) -> [Double] {
        let centers = Band.allCases.map(\.hue)
        var weights = [Double](repeating: 0, count: centers.count)
        for i in centers.indices {
            let start = centers[i]
            let end = i + 1 < centers.count ? centers[i + 1] : 360
            guard h >= start, h < end else { continue }
            let t = (h - start) / (end - start)
            weights[i] = 1 - t
            weights[(i + 1) % centers.count] = t
        }
        return weights
    }

    func apply(_ color: RGB) -> RGB {
        let (h, s, l) = rgbToHSL(color)
        guard s > 0.001 else { return color }
        let weights = Self.weights(for: h)
        var hueShift = 0.0, satScale = 0.0, lumShift = 0.0
        for i in weights.indices where weights[i] > 0 {
            hueShift += weights[i] * hue[i]
            satScale += weights[i] * saturation[i]
            lumShift += weights[i] * luminance[i]
        }
        let newHue = h + hueShift * 30
        let newSat = min(1, max(0, s * (1 + satScale)))
        // Luminance acts in proportion to how colorful the pixel is.
        let newLum = min(1, max(0, l + lumShift * 0.25 * s * (lumShift > 0 ? 1 - l : l) * 2))
        return hslToRGB(newHue, newSat, newLum)
    }
}

/// Lightroom's Black & White Mix: each color band's slider makes that color lighter or darker
/// gray than its plain luminance, in proportion to how colorful it was. Grays stay as they are.
struct BWMix {
    typealias Band = DevelopSettings.ColorBand
    private let mix: [Double]

    init(_ settings: DevelopSettings) {
        mix = Band.allCases.map { settings[.gray($0)] / 100 }
    }

    func apply(_ color: RGB) -> RGB {
        let y = luma(color)
        let (h, s, _) = rgbToHSL(color)
        var shift = 0.0
        if s > 0.001 {
            let weights = HSLAdjustment.weights(for: h)
            for i in weights.indices where weights[i] > 0 { shift += weights[i] * mix[i] }
        }
        // At +100 a saturated color moves most of the way to white; at -100 most of the way to black.
        let gray = min(1, max(0, y + shift * s * 0.8 * (shift > 0 ? 1 - y : y)))
        return (gray, gray, gray)
    }
}

/// Lightroom-style color grading: tint shadows, midtones and highlights separately (and the
/// whole photo with Global), with Blending widening the overlap and Balance moving the split.
///
/// The hue numbers are Lightroom's (0 red, 60 yellow, 120 green, 240 blue), but each tint is
/// built in Oklab, so the same Saturation looks equally strong at every hue. Luminance raises or
/// lowers lightness with a roll-off toward white and black, so it never clips; a tint that would
/// leave the screen's colors is shortened instead of clipped, so it keeps its hue.
public struct ColorGrade {
    public typealias Region = DevelopSettings.GradeRegion
    /// Oklab chroma a wheel adds at Saturation 100 where its range has full weight.
    static let chroma = 0.10
    /// How far Luminance ±100 moves lightness, as a share of the way to white or black.
    static let luminanceStrength = 0.3

    /// Per region, in `Region.allCases` order: the Oklab a/b tint at full weight and Luminance (-1...1).
    private let tints: [(SIMD2<Double>, Double)]
    private let blending: Double
    private let balance: Double
    let isActive: Bool

    init(_ settings: DevelopSettings) {
        tints = Region.allCases.map { region in
            (Self.direction(hue: settings[region.hue]) * (settings[region.saturation] / 100 * Self.chroma),
             settings[region.luminance] / 100)
        }
        blending = settings[.gradeBlending] / 100
        balance = settings[.gradeBalance] / 100
        isActive = settings.isOn(.colorGrading)
            && Region.allCases.contains { settings[$0.saturation] != 0 || settings[$0.luminance] != 0 }
    }

    /// Shadow, midtone, highlight and global weights for a luminance.
    func weights(for y: Double) -> [Double] {
        Self.weights(luma: y, blending: blending, balance: balance)
    }

    /// Shadow, midtone, highlight and global weights for an sRGB-encoded luma, with Blending
    /// (0...1) and Balance (-1...1) as fractions of their sliders.
    public static func weights(luma y: Double, blending: Double, balance: Double) -> [Double] {
        let pivot = 0.5 - balance * 0.3
        let exponent = 2.5 - 2 * blending
        let shadows = pow(max(0, 1 - y / pivot), exponent)
        let highlights = pow(max(0, (y - pivot) / (1 - pivot)), exponent)
        return [shadows, max(0, 1 - shadows - highlights), highlights, 1]
    }

    /// The position of `region` in `Region.allCases` and in `weights`.
    public static func index(of region: Region) -> Int {
        Region.allCases.firstIndex(of: region) ?? 0
    }

    func apply(_ color: RGB) -> RGB {
        let weights = self.weights(for: luma(color))
        var shift = SIMD2<Double>(0, 0)
        var lift = 0.0
        for (i, (tint, luminance)) in tints.enumerated() {
            shift += tint * weights[i]
            lift += luminance * weights[i]
        }
        var lab = Oklab.fromEncoded(color)
        let lightness = lab.x
        lab.x = min(1, max(0, lightness + lift * Self.luminanceStrength * (lift > 0 ? 1 - lightness : lightness)))
        // A new lightness can put a vivid color out of gamut: keep its hue and lower its chroma.
        if !Oklab.inGamut(lab) {
            let base = lab
            let scale = Self.largestFraction { Oklab.inGamut(SIMD3(base.x, base.y * $0, base.z * $0)) }
            lab.y *= scale
            lab.z *= scale
        }
        let start = lab
        let reach = Self.largestFraction { Oklab.inGamut(SIMD3(start.x, start.y + shift.x * $0, start.z + shift.y * $0)) }
        lab.y += shift.x * reach
        lab.z += shift.y * reach
        return Oklab.toEncoded(lab)
    }

    /// The largest t in 0...1 for which `fits` holds, given it holds at 0 and fails past some point.
    static func largestFraction(_ fits: (Double) -> Bool) -> Double {
        if fits(1) { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }

    // MARK: Hues

    /// The Oklab a/b direction (unit length) each whole-degree hue tints toward. Red, yellow,
    /// green, cyan, blue and magenta (0, 60 ... 300) point at their pure colors, and the hues
    /// between turn evenly from one to the next: the HSL hues between them bunch up in Oklab
    /// (226 to 242 all point almost the same way), which would leave dead spots on the wheel.
    static let directions: [SIMD2<Double>] = {
        var anchors = (0..<6).map { k -> Double in
            let lab = Oklab.fromEncoded(hslToRGB(Double(k * 60), 1, 0.5))
            return atan2(lab.z, lab.y)
        }
        // Unwrap so the angles rise around the circle.
        for k in 1..<6 { while anchors[k] < anchors[k - 1] { anchors[k] += 2 * .pi } }
        anchors.append(anchors[0] + 2 * .pi)
        return (0..<360).map { hue in
            let k = hue / 60, t = Double(hue % 60) / 60
            let angle = anchors[k] + (anchors[k + 1] - anchors[k]) * t
            return SIMD2(cos(angle), sin(angle))
        }
    }()

    /// The Oklab a/b direction (unit length) a wheel at `hue` tints toward.
    public static func direction(hue: Double) -> SIMD2<Double> {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let i = min(359, Int(h)), t = h - Double(i)
        let mixed = directions[i] * (1 - t) + directions[(i + 1) % 360] * t
        return mixed / max(1e-9, (mixed * mixed).sum().squareRoot())
    }

    /// The whole-degree hue whose tint points most nearly along `ab` in Oklab.
    public static func hue(towards ab: SIMD2<Double>) -> Double {
        let length = (ab * ab).sum().squareRoot()
        guard length > 1e-9 else { return 0 }
        let unit = ab / length
        var best = 0, bestDot = -2.0
        for (hue, direction) in directions.enumerated() {
            let dot = (direction * unit).sum()
            if dot > bestDot {
                best = hue
                bestDot = dot
            }
        }
        return Double(best)
    }

    /// Mid gray tinted by a wheel at full weight, sRGB-encoded: the color the wheel's dot shows.
    public static func swatch(hue: Double, saturation: Double) -> (red: Double, green: Double, blue: Double) {
        var settings = DevelopSettings()
        settings[.gradeGlobalHue] = hue
        settings[.gradeGlobalSat] = saturation
        let color = ColorGrade(settings).apply((0.5, 0.5, 0.5))
        return (color.0, color.1, color.2)
    }

    // MARK: Views and tools

    /// Balance's Option-drag view: each tone in the color of its range (blue shadows, gray
    /// midtones, yellow highlights), mixed where the ranges overlap.
    func regionMap(_ color: RGB) -> RGB {
        let weights = self.weights(for: luma(color))
        let colors: [RGB] = [(0.2, 0.4, 0.95), (0.5, 0.5, 0.5), (1, 0.8, 0.25)]
        let total = max(1e-6, weights[0] + weights[1] + weights[2])
        var out: RGB = (0, 0, 0)
        for i in 0..<3 {
            out.0 += colors[i].0 * weights[i] / total
            out.1 += colors[i].1 * weights[i] / total
            out.2 += colors[i].2 * weights[i] / total
        }
        return out
    }

    /// A wheel setting that turns a color cast neutral.
    public struct Neutralizing: Sendable, Equatable {
        public var region: Region
        public var hue: Double
        public var saturation: Double
    }

    /// The wheel setting that cancels the cast of `sample` (the photo's sRGB-encoded color at a
    /// spot, as rendered with `settings`): `region`'s wheel, or with nil the shadows, midtones or
    /// highlights wheel that covers the spot most. Nil when the spot is barely in that range.
    public static func neutralizing(_ sample: SIMD3<Double>, settings: DevelopSettings, region: Region?) -> Neutralizing? {
        let color: RGB = (sample.x, sample.y, sample.z)
        let weights = Self.weights(luma: luma(color), blending: settings[.gradeBlending] / 100,
                                   balance: settings[.gradeBalance] / 100)
        let tonal: [Region] = [.shadows, .midtones, .highlights]
        let chosen = region ?? tonal.max { weights[index(of: $0)] < weights[index(of: $1)] } ?? .midtones
        let weight = weights[index(of: chosen)]
        guard weight > 0.15 else { return nil }
        let lab = Oklab.fromEncoded(color)
        let cast = SIMD2(lab.y, lab.z)
        let current = direction(hue: settings[chosen.hue]) * (settings[chosen.saturation] / 100 * chroma)
        let wanted = current - cast / weight
        let saturation = min(100, ((wanted * wanted).sum().squareRoot() / chroma * 100).rounded())
        return Neutralizing(region: chosen, hue: saturation > 0 ? hue(towards: wanted) : settings[chosen.hue],
                            saturation: saturation)
    }
}
