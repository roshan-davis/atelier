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

    /// RGBA float cube data, or nil when both panels are at their defaults.
    static func cube(for settings: DevelopSettings) -> Data? {
        let key = parameters.map { settings[$0] }
        let neutral = parameters.map { $0.defaultValue }
        guard key != neutral else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if key == cachedKey, let cachedCube { return cachedCube }
        let cube = build(HSLAdjustment(settings), ColorGrade(settings))
        cachedKey = key
        cachedCube = cube
        return cube
    }

    private static func build(_ hsl: HSLAdjustment, _ grade: ColorGrade) -> Data {
        let n = dimension
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        // Core Image cubes vary red fastest, then green, then blue.
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var rgb = (Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                    if hsl.isActive { rgb = hsl.apply(rgb) }
                    if grade.isActive { rgb = grade.apply(rgb) }
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

/// Lightroom-style color grading: tint shadows, midtones and highlights separately (and the
/// whole photo with Global), with Blending widening the overlap and Balance moving the split.
struct ColorGrade {
    typealias Region = DevelopSettings.GradeRegion
    private let tints: [(RGB, Double)]
    private let blending: Double
    private let balance: Double
    let isActive: Bool

    init(_ settings: DevelopSettings) {
        tints = Region.allCases.map { region in
            let saturation = settings[region.saturation] / 100
            let hueColor = hslToRGB(settings[region.hue], 1, 0.5)
            let y = luma(hueColor)
            let offset = (hueColor.0 - y, hueColor.1 - y, hueColor.2 - y)
            return ((offset.0 * saturation * 0.3, offset.1 * saturation * 0.3, offset.2 * saturation * 0.3),
                    settings[region.luminance] / 100 * 0.2)
        }
        blending = settings[.gradeBlending] / 100
        balance = settings[.gradeBalance] / 100
        isActive = Region.allCases.contains { settings[$0.saturation] != 0 || settings[$0.luminance] != 0 }
    }

    /// Shadow, midtone, highlight and global weights for a luminance.
    func weights(for y: Double) -> [Double] {
        let pivot = 0.5 - balance * 0.3
        let exponent = 2.5 - 2 * blending
        let shadows = pow(max(0, 1 - y / pivot), exponent)
        let highlights = pow(max(0, (y - pivot) / (1 - pivot)), exponent)
        return [shadows, max(0, 1 - shadows - highlights), highlights, 1]
    }

    func apply(_ color: RGB) -> RGB {
        let weights = self.weights(for: luma(color))
        var out = color
        for (i, (offset, lum)) in tints.enumerated() {
            let w = weights[i]
            out.0 += w * (offset.0 + lum)
            out.1 += w * (offset.1 + lum)
            out.2 += w * (offset.2 + lum)
        }
        return out
    }
}
