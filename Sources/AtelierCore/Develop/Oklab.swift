import Foundation

/// Oklab (Björn Ottosson, 2020): a perceptual color space where equal steps of a and b look like
/// equal changes of color at any hue. Color Grading tints in it so every hue is equally strong.
enum Oklab {
    /// sRGB-encoded (0...1) to linear.
    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear to sRGB-encoded.
    static func encoded(_ c: Double) -> Double {
        let c = max(0, c)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// Linear sRGB to Oklab L, a, b.
    static func fromLinear(_ r: Double, _ g: Double, _ b: Double) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Oklab to linear sRGB; may fall outside 0...1 when the color is out of gamut.
    static func toLinear(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// sRGB-encoded color to Oklab.
    static func fromEncoded(_ c: RGB) -> SIMD3<Double> {
        fromLinear(linear(c.0), linear(c.1), linear(c.2))
    }

    static func inGamut(_ lab: SIMD3<Double>) -> Bool {
        let c = toLinear(lab)
        return c.x >= -1e-6 && c.y >= -1e-6 && c.z >= -1e-6 && c.x <= 1 + 1e-6 && c.y <= 1 + 1e-6 && c.z <= 1 + 1e-6
    }

    /// Oklab to sRGB-encoded, clipped to 0...1.
    static func toEncoded(_ lab: SIMD3<Double>) -> RGB {
        let c = toLinear(lab)
        return (min(1, encoded(c.x)), min(1, encoded(c.y)), min(1, encoded(c.z)))
    }
}
