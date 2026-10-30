import Foundation

/// Oklab (Björn Ottosson, 2020): a perceptual color space where equal steps of a and b look like
/// equal changes of color at any hue. Color Grading, HSL and Point Color work in it so every hue
/// is equally strong and lightness means what the eye sees.
///
/// The conversions take and give sRGB values without clipping: colors outside sRGB (Display P3's
/// vivid reds and greens) come in as values below 0 or above 1 and go back out the same way.
enum Oklab {
    /// sRGB-encoded to linear, mirrored below 0 so colors outside sRGB survive.
    static func linear(_ c: Double) -> Double {
        let magnitude = abs(c)
        let value = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return c < 0 ? -value : value
    }

    /// Linear to sRGB-encoded, mirrored below 0.
    static func encoded(_ c: Double) -> Double {
        let magnitude = abs(c)
        let value = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return c < 0 ? -value : value
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

    /// Whether the color fits Display P3, the screen's gamut and the color cube's.
    static func inDisplayP3(_ lab: SIMD3<Double>) -> Bool {
        let c = linearP3(fromLinearSRGB: toLinear(lab))
        return c.x >= -1e-6 && c.y >= -1e-6 && c.z >= -1e-6 && c.x <= 1 + 1e-6 && c.y <= 1 + 1e-6 && c.z <= 1 + 1e-6
    }

    /// Oklab to sRGB-encoded, clipped to 0...1.
    static func toEncoded(_ lab: SIMD3<Double>) -> RGB {
        let c = toLinear(lab)
        return (min(1, encoded(max(0, c.x))), min(1, encoded(max(0, c.y))), min(1, encoded(max(0, c.z))))
    }

    /// Oklab to sRGB-encoded, unclipped: values outside 0...1 are colors outside sRGB.
    static func toEncodedExtended(_ lab: SIMD3<Double>) -> RGB {
        let c = toLinear(lab)
        return (encoded(c.x), encoded(c.y), encoded(c.z))
    }

    // MARK: Lightness, chroma, hue

    /// Chroma (colorfulness) and hue angle in degrees, 0..<360.
    static func chromaHue(_ lab: SIMD3<Double>) -> (chroma: Double, hue: Double) {
        let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var hue = atan2(lab.z, lab.y) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (chroma, hue)
    }

    static func lab(lightness: Double, chroma: Double, hue: Double) -> SIMD3<Double> {
        let radians = hue * .pi / 180
        return SIMD3(lightness, chroma * cos(radians), chroma * sin(radians))
    }

    /// `lab` with its chroma lowered (lightness and hue kept) until it fits Display P3.
    static func fittedToDisplayP3(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        guard !inDisplayP3(lab) else { return lab }
        let light = min(1, max(0, lab.x))
        let scale = ColorGrade.largestFraction { inDisplayP3(SIMD3(light, lab.y * $0, lab.z * $0)) }
        return SIMD3(light, lab.y * scale, lab.z * scale)
    }

    // MARK: Display P3

    /// Linear sRGB to linear Display P3 (both D65).
    static func linearP3(fromLinearSRGB c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.8224621 * c.x + 0.1775380 * c.y,
              0.0331941 * c.x + 0.9668058 * c.y,
              0.0170827 * c.x + 0.0723974 * c.y + 0.9105199 * c.z)
    }

    /// Linear Display P3 to linear sRGB.
    static func linearSRGB(fromLinearP3 c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(1.2249401 * c.x - 0.2249404 * c.y,
              -0.0420569 * c.x + 1.0420571 * c.y,
              -0.0196376 * c.x - 0.0786361 * c.y + 1.0982735 * c.z)
    }

    /// A Display P3-encoded color as sRGB-encoded values, unclipped.
    static func encodedSRGB(fromP3 c: RGB) -> RGB {
        let s = linearSRGB(fromLinearP3: SIMD3(linear(c.0), linear(c.1), linear(c.2)))
        return (encoded(s.x), encoded(s.y), encoded(s.z))
    }

    /// An sRGB-encoded color (possibly outside 0...1) as Display P3-encoded values, unclipped.
    static func encodedP3(fromSRGB c: RGB) -> RGB {
        let p = linearP3(fromLinearSRGB: SIMD3(linear(c.0), linear(c.1), linear(c.2)))
        return (encoded(p.x), encoded(p.y), encoded(p.z))
    }
}
