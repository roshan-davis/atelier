import CoreGraphics
import Foundation

/// Builds the color cube for the HSL / Color and Color Grading panels. All of them are per-pixel
/// color mappings, so one 3D lookup table applies them together on the GPU.
///
/// The cube spans Display P3 (the screen's gamut, with sRGB's tone curve), not sRGB: a cube's
/// lookup clamps its input to the cube, so an sRGB cube flattened every color beyond sRGB (deep
/// reds, magentas, cyan water) the moment an HSL slider or a wheel moved. The adjustments
/// themselves work on sRGB-encoded values that may fall outside 0...1 for those colors.
enum ColorLUT {
    static let dimension = 32
    static let space = CGColorSpace(name: CGColorSpace.displayP3)!

    private static let lock = NSLock()
    /// Off only for the before/after benchmark (`SliderPerformanceTests`).
    nonisolated(unsafe) static var buildsInParallel = true
    /// The last few cubes, newest last. More than one: a render with a graded mask needs the
    /// panel's cube and the mask's, and a single entry would rebuild both on every frame.
    nonisolated(unsafe) private static var cached: [(key: [Double], cube: Data)] = []
    static let cacheSize = 4

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
        if let index = cached.firstIndex(where: { $0.key == key }) {
            let hit = cached.remove(at: index)
            cached.append(hit)
            return hit.cube
        }
        let color = ColorMix(settings), grade = ColorGrade(settings)
        // In Black & White, the B&W Mix replaces HSL and Point Color; color grading then tones the grays.
        let cube = RenderSignposts.measure("Color cube") {
            build { rgb in
                let mixed = color.apply(rgb)
                return grade.isActive ? grade.apply(mixed) : mixed
            }
        }
        cached.append((key, cube))
        if cached.count > cacheSize { cached.removeFirst(cached.count - cacheSize) }
        return cube
    }

    /// Color Grading Balance's Option-drag view: the colors after HSL, mapped to the color of the
    /// tonal range each falls in (see `ColorGrade.regionMap`).
    static func regionMapCube(for settings: DevelopSettings) -> Data {
        let color = ColorMix(settings), grade = ColorGrade(settings)
        return build { grade.regionMap(color.apply($0)) }
    }

    /// Point Color's Visualize Range: the colors after HSL, kept where `swatch` selects them
    /// and gray elsewhere.
    static func pointRangeCube(for settings: DevelopSettings, swatch: Int) -> Data {
        let hsl = HSLAdjustment(settings)
        let selection = PointColorAdjustment.Swatch(settings, index: swatch)
        return build { rgb in
            let lab = Oklab.fromEncoded(hsl.isActive && !settings.monochrome ? hsl.apply(rgb) : rgb)
            let weight = selection.map { $0.selection(lab) } ?? 0
            return Oklab.toEncodedExtended(SIMD3(lab.x, lab.y * weight, lab.z * weight))
        }
    }

    /// `map` takes and gives sRGB-encoded colors, which may lie outside 0...1; the cube's own
    /// grid and output are Display P3-encoded.
    private static func build(_ map: (RGB) -> RGB) -> Data {
        let n = dimension
        var values = [Float](repeating: 0, count: n * n * n * 4)
        // Rebuilt on every tick of an HSL or wheel drag, so spread it over the cores: each blue
        // slice is independent, and `map` only reads its settings.
        values.withUnsafeMutableBufferPointer { buffer in
            let output = buffer
            func slice(_ b: Int) {
                // Core Image cubes vary red fastest, then green, then blue.
                var index = b * n * n * 4
                for g in 0..<n {
                    for r in 0..<n {
                        let node: RGB = (Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                        let rgb = Oklab.encodedP3(fromSRGB: map(Oklab.encodedSRGB(fromP3: node)))
                        output[index] = Float(min(1, max(0, rgb.0)))
                        output[index + 1] = Float(min(1, max(0, rgb.1)))
                        output[index + 2] = Float(min(1, max(0, rgb.2)))
                        output[index + 3] = 1
                        index += 4
                    }
                }
            }
            if buildsInParallel {
                DispatchQueue.concurrentPerform(iterations: n) { slice($0) }
            } else {
                for b in 0..<n { slice(b) }
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

/// The HSL / Color panel as one mapping: HSL then Point Color, or in Black & White the B&W Mix.
struct ColorMix {
    let hsl: HSLAdjustment
    let points: PointColorAdjustment
    let bw: BWMix?

    init(_ settings: DevelopSettings) {
        hsl = HSLAdjustment(settings)
        points = PointColorAdjustment(settings)
        bw = settings.monochrome ? BWMix(settings) : nil
    }

    func apply(_ rgb: RGB) -> RGB {
        if let bw { return bw.apply(rgb) }
        guard hsl.isActive || points.isActive else { return rgb }
        var lab = Oklab.fromEncoded(rgb)
        if hsl.isActive { lab = hsl.apply(lab) }
        if points.isActive { lab = points.apply(lab) }
        return Oklab.toEncodedExtended(lab)
    }
}

/// Lightroom-style HSL: eight overlapping hue bands, each turning the hue, scaling the
/// saturation and raising or lowering the luminance of the colors it covers.
///
/// It works in Oklab's lightness, chroma and hue, so the sliders act the way the eye sees:
/// Saturation -100 leaves a color's brightness as it was (in HSL math pure blue turned 50% gray),
/// Luminance moves perceived brightness, and grays, near-blacks and near-whites (whose noise
/// HSL math counted as colorful) are left alone. A change that would leave Display P3 lowers the
/// color's chroma instead of clipping it, so it keeps its hue.
struct HSLAdjustment {
    typealias Band = DevelopSettings.ColorBand
    private let hueShift: [Double]
    private let saturation: [Double]
    private let luminance: [Double]
    let isActive: Bool

    init(_ settings: DevelopSettings) {
        hueShift = Band.allCases.map { settings[.hsl(.hue, $0)] / 100 }
        saturation = Band.allCases.map { settings[.hsl(.saturation, $0)] / 100 }
        luminance = Band.allCases.map { settings[.hsl(.luminance, $0)] / 100 }
        isActive = (hueShift + saturation + luminance).contains { $0 != 0 }
    }

    /// Each band's center as an Oklab hue: where its namesake (the pure sRGB red, orange, yellow
    /// ... at full HSL saturation) sits. Rising, from red at about 29°.
    static let centers: [Double] = Band.allCases.map { band in
        Oklab.chromaHue(Oklab.fromEncoded(hslToRGB(band.hue, 1, 0.5))).hue
    }

    /// Weights of the eight bands for an Oklab hue: linear between neighboring band centers, so
    /// they always sum to 1.
    static func weights(for hue: Double) -> [Double] {
        let count = centers.count
        var h = hue
        if h < centers[0] { h += 360 }
        var weights = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let start = centers[i]
            let end = i + 1 < count ? centers[i + 1] : centers[0] + 360
            guard h >= start, h < end else { continue }
            let t = (h - start) / (end - start)
            weights[i] = 1 - t
            weights[(i + 1) % count] = t
        }
        return weights
    }

    /// Degrees a band's Hue slider turns its colors at +100 (toward the next band) or -100
    /// (toward the previous one): three quarters of the way to that band's center.
    static func hueReach(_ band: Int, positive: Bool) -> Double {
        let count = centers.count
        let gap = positive
            ? (band + 1 < count ? centers[band + 1] : centers[0] + 360) - centers[band]
            : centers[band] - (band > 0 ? centers[band - 1] : centers[count - 1] - 360)
        return 0.75 * gap
    }

    /// How fully a color of this Oklab chroma is treated as a color: 0 for grays and the faint
    /// tints of noise, 1 from a pastel's chroma up.
    static func colorfulness(_ chroma: Double) -> Double {
        let t = min(1, chroma / 0.03)
        return t * t * (3 - 2 * t)
    }

    /// How strongly Luminance (and the B&W Mix) moves a color of this chroma: in proportion to
    /// how vivid it is, full from about skin-tone strength up.
    static func strength(_ chroma: Double) -> Double {
        min(1, chroma / 0.15)
    }

    func apply(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let (chroma, hue) = Oklab.chromaHue(lab)
        let gate = Self.colorfulness(chroma)
        guard gate > 0 else { return lab }
        let weights = Self.weights(for: hue)
        var turn = 0.0, scale = 0.0, lift = 0.0
        for i in weights.indices where weights[i] > 0 {
            turn += weights[i] * hueShift[i] * Self.hueReach(i, positive: hueShift[i] > 0)
            scale += weights[i] * saturation[i]
            lift += weights[i] * luminance[i]
        }
        let lightness = lab.x
        let newLightness = lightness + lift * 0.5 * Self.strength(chroma) * (lift > 0 ? 1 - lightness : lightness)
        let newChroma = chroma * max(0, 1 + scale * gate)
        let result = Oklab.lab(lightness: min(1, max(0, newLightness)), chroma: newChroma, hue: hue + turn * gate)
        return Oklab.fittedToDisplayP3(result)
    }

    /// The same on an sRGB-encoded color.
    func apply(_ color: RGB) -> RGB {
        let lab = Oklab.fromEncoded(color)
        let result = apply(lab)
        return result == lab ? color : Oklab.toEncodedExtended(result)
    }
}

/// Lightroom's Point Color: pick a color, then shift the hue, saturation and luminance of the
/// colors near it. Range widens or narrows which colors count as near (by hue, lightness and
/// chroma, with a soft edge). Uniformity, from Capture One's skin tone tool, pulls the selected
/// colors toward the picked one, evening out blotchy skin or a patchy sky.
struct PointColorAdjustment {
    struct Swatch {
        var lightness: Double
        var chroma: Double
        var hue: Double
        var hueShift: Double
        var satShift: Double
        var lumShift: Double
        var range: Double
        var uniformity: Double

        /// Swatch `index` of `settings`, or nil when it has no picked color.
        init?(_ settings: DevelopSettings, index: Int) {
            guard settings.hasPointColor(index) else { return nil }
            func value(_ setting: DevelopSettings.PointColorSetting) -> Double {
                settings[.pointColor(index, setting)]
            }
            lightness = value(.lightness) / 100
            chroma = value(.chroma) / 100
            hue = value(.hue)
            hueShift = value(.hueShift) / 100
            satShift = value(.satShift) / 100
            lumShift = value(.lumShift) / 100
            range = value(.range) / 100
            uniformity = value(.uniformity) / 100
        }

        var isActive: Bool { hueShift != 0 || satShift != 0 || lumShift != 0 || uniformity != 0 }

        /// How much a color belongs to this swatch, 0...1: full near the picked color, fading to
        /// nothing at the edge of the range.
        func selection(_ lab: SIMD3<Double>) -> Double {
            let (c, h) = Oklab.chromaHue(lab)
            var dh = abs(h - hue).truncatingRemainder(dividingBy: 360)
            if dh > 180 { dh = 360 - dh }
            let hueWidth = 10 + 50 * range
            let lightWidth = 0.12 + 0.5 * range
            let chromaWidth = 0.6 * chroma + 0.1 * range + 0.02
            return Self.falloff(dh / hueWidth) * Self.falloff(abs(lab.x - lightness) / lightWidth)
                * Self.falloff(abs(c - chroma) / chromaWidth) * HSLAdjustment.colorfulness(c)
        }

        static func falloff(_ t: Double) -> Double {
            guard t < 1 else { return 0 }
            let u = 1 - t * t
            return u * u
        }

        func apply(_ lab: SIMD3<Double>) -> SIMD3<Double> {
            let w = selection(lab)
            guard w > 0 else { return lab }
            var (c, h) = Oklab.chromaHue(lab)
            var l = lab.x
            if uniformity != 0 {
                var dh = (h - hue).truncatingRemainder(dividingBy: 360)
                if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
                h -= w * uniformity * dh
                c += w * uniformity * (chroma - c)
                // Lightness evens out less, so the shading that gives a face its shape stays.
                l += w * uniformity * 0.35 * (lightness - l)
            }
            h += w * hueShift * 30
            c *= max(0, 1 + w * satShift)
            l += w * lumShift * 0.5 * (lumShift > 0 ? 1 - l : l)
            return Oklab.fittedToDisplayP3(Oklab.lab(lightness: min(1, max(0, l)), chroma: c, hue: h))
        }
    }

    let swatches: [Swatch]
    var isActive: Bool { !swatches.isEmpty }

    init(_ settings: DevelopSettings) {
        swatches = (0..<DevelopSettings.pointColorCount).compactMap { Swatch(settings, index: $0) }.filter(\.isActive)
    }

    func apply(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        swatches.reduce(lab) { $1.apply($0) }
    }

    /// The color a swatch picks from an sRGB-encoded sample: Oklab hue, chroma ×100 and
    /// lightness ×100, as stored. Nil for a gray, which has no color to pick.
    static func target(of sample: SIMD3<Double>) -> (hue: Double, chroma: Double, lightness: Double)? {
        let lab = Oklab.fromEncoded((sample.x, sample.y, sample.z))
        let (chroma, hue) = Oklab.chromaHue(lab)
        guard chroma >= 0.02 else { return nil }
        return ((hue * 10).rounded() / 10, min(50, (chroma * 1000).rounded() / 10), min(100, (lab.x * 1000).rounded() / 10))
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
        let (chroma, hue) = Oklab.chromaHue(Oklab.fromEncoded(color))
        var shift = 0.0
        let strength = HSLAdjustment.strength(chroma) * HSLAdjustment.colorfulness(chroma)
        if strength > 0 {
            let weights = HSLAdjustment.weights(for: hue)
            for i in weights.indices where weights[i] > 0 { shift += weights[i] * mix[i] }
        }
        // At +100 a saturated color moves most of the way to white; at -100 most of the way to black.
        let gray = min(1, max(0, y + shift * strength * 0.8 * (shift > 0 ? 1 - y : y)))
        return (gray, gray, gray)
    }
}

/// Lightroom-style color grading: tint shadows, midtones and highlights separately (and the
/// whole photo with Global), with Blending widening the overlap and Balance moving the split.
///
/// The hue numbers are Lightroom's (0 red, 60 yellow, 120 green, 240 blue), but each tint is
/// built in Oklab, so the same Saturation looks equally strong at every hue. Luminance raises or
/// lowers lightness with a roll-off toward white and black, so it never clips; a tint that would
/// leave the screen's colors (Display P3) is shortened instead of clipped, so it keeps its hue.
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
        lab = Oklab.fittedToDisplayP3(lab)
        let start = lab
        let reach = Self.largestFraction { Oklab.inDisplayP3(SIMD3(start.x, start.y + shift.x * $0, start.z + shift.y * $0)) }
        lab.y += shift.x * reach
        lab.z += shift.y * reach
        return Oklab.toEncodedExtended(lab)
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
        return (min(1, max(0, color.0)), min(1, max(0, color.1)), min(1, max(0, color.2)))
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
