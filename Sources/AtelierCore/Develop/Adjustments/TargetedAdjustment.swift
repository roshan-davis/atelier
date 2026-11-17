import Foundation

/// What Lightroom's Targeted Adjustment Tool and Point Color's eyedropper need to know about a
/// color clicked on the photo, worked out the same way the panels apply their sliders.
public enum TargetedAdjustment {
    /// How much each HSL band (Red ... Magenta) covers a sampled sRGB-encoded color: the share
    /// a drag on it gives each band's slider. Nil for a gray, which no band moves.
    public static func bandWeights(of sample: SIMD3<Double>) -> [Double]? {
        let (chroma, hue) = Oklab.chromaHue(Oklab.fromEncoded((sample.x, sample.y, sample.z)))
        guard chroma >= 0.02 else { return nil }
        return HSLAdjustment.weights(for: hue)
    }

    /// The sRGB-encoded luma of a sample, the tone the curve sees.
    public static func tone(of sample: SIMD3<Double>) -> Double {
        min(1, max(0, luma((sample.x, sample.y, sample.z))))
    }

    /// How much each Tone Curve region (Shadows, Darks, Lights, Highlights) covers a tone, the
    /// largest being 1: a drag moves each region's slider by this share.
    public static func regionWeights(tone: Double, settings: DevelopSettings) -> [Double] {
        let (low, middle, high) = DevelopRenderer.curveSplits(settings)
        let centers = [low / 2, (low + middle) / 2, (middle + high) / 2, (high + 1) / 2]
        let edges = [0.0] + centers + [1.0]
        let weights = centers.indices.map { i -> Double in
            let left = edges[i], center = edges[i + 1], right = edges[i + 2]
            // Below the Shadows center and above the Highlights center, that region has it all.
            if tone <= center { return i == 0 ? 1 : max(0, (tone - left) / (center - left)) }
            return i == centers.count - 1 ? 1 : max(0, (right - tone) / (right - center))
        }
        let largest = weights.max() ?? 0
        return largest > 0 ? weights.map { $0 / largest } : weights
    }

    /// The color a Point Color swatch takes from an sRGB-encoded sample, as stored in its Hue,
    /// Chroma and Lightness parameters. Nil for a gray, which has no color to pick.
    public static func pointColor(of sample: SIMD3<Double>) -> (hue: Double, chroma: Double, lightness: Double)? {
        PointColorAdjustment.target(of: sample)
    }

    /// A Point Color swatch's picked color as sRGB-encoded values, for drawing the swatch.
    public static func swatchColor(_ settings: DevelopSettings, swatch: Int) -> (red: Double, green: Double, blue: Double)? {
        guard settings.hasPointColor(swatch) else { return nil }
        let lab = Oklab.lab(lightness: settings[.pointColor(swatch, .lightness)] / 100,
                            chroma: settings[.pointColor(swatch, .chroma)] / 100,
                            hue: settings[.pointColor(swatch, .hue)])
        let color = Oklab.toEncoded(Oklab.fittedToDisplayP3(lab))
        return (color.0, color.1, color.2)
    }
}
