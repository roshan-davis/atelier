import CoreImage
import Foundation

/// Lightroom's Calibration panel (AT-069): Shadows Tint and the Red, Green and Blue primaries'
/// Hue and Saturation. It reshapes the profile's primaries, so it works on the whole photo
/// before every other color step, in the linear working space (Rec. 2020).
///
/// Each primary (the working space's pure red, green or blue) is turned around the gray axis
/// (Hue: positive moves red toward orange, green toward cyan, blue toward purple, as in
/// Lightroom) and pushed away from or toward gray (Saturation). The three moved primaries make a
/// 3 × 3 matrix, scaled so white stays white. Shadows Tint then adds green (left) or magenta
/// (right) in the shadows, keeping each pixel's brightness.
enum Calibration {
    /// Hue at ±100 turns a primary this far, in radians (30°).
    static let maxTurn = Double.pi / 6
    /// Saturation at ±100 scales a primary's distance from gray by 1 ∓ this.
    static let maxSaturation = 0.6
    /// Shadows Tint at ±100 changes green by this share in the deepest shadows.
    static let maxTint = 0.16

    /// Whether `settings` change anything here.
    static func isNeutral(_ settings: DevelopSettings) -> Bool {
        DevelopSettings.Panel.calibration.parameters.allSatisfy { settings[$0] == 0 }
    }

    /// The primaries' matrix as rows (working RGB in, working RGB out), or nil when the primaries
    /// are untouched.
    static func matrix(_ settings: DevelopSettings) -> [SIMD3<Double>]? {
        let hues: [DevelopSettings.Parameter] = [.calibrationRedHue, .calibrationGreenHue, .calibrationBlueHue]
        let sats: [DevelopSettings.Parameter] = [.calibrationRedSat, .calibrationGreenSat, .calibrationBlueSat]
        guard (hues + sats).contains(where: { settings[$0] != 0 }) else { return nil }
        let gray = SIMD3<Double>(1.0 / 3, 1.0 / 3, 1.0 / 3)
        var columns: [SIMD3<Double>] = []
        for i in 0..<3 {
            var primary = SIMD3<Double>(0, 0, 0)
            primary[i] = 1
            let turned = rotatedAroundGray(primary, by: settings[hues[i]] / 100 * maxTurn)
            let scale: Double = 1 + settings[sats[i]] / 100 * maxSaturation
            columns.append(gray + (turned - gray) * scale)
        }
        // Scale each column so (1, 1, 1) still comes out as (1, 1, 1).
        guard let weights = solve(columns, SIMD3<Double>(1, 1, 1)) else { return nil }
        let scaled = (0..<3).map { columns[$0] * weights[$0] }
        return (0..<3).map { row in SIMD3<Double>(scaled[0][row], scaled[1][row], scaled[2][row]) }
    }

    /// `v` turned by `angle` around the gray axis (Rodrigues' rotation).
    static func rotatedAroundGray(_ v: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        let k = 1 / Double(3).squareRoot()
        let axis = SIMD3<Double>(k, k, k)
        let cross = SIMD3<Double>(axis.y * v.z - axis.z * v.y, axis.z * v.x - axis.x * v.z, axis.x * v.y - axis.y * v.x)
        let along: Double = (axis * v).sum() * (1 - cos(angle))
        return v * cos(angle) + cross * sin(angle) + axis * along
    }

    /// Solves `columns` × x = b (Cramer's rule); nil when the columns are degenerate.
    private static func solve(_ columns: [SIMD3<Double>], _ b: SIMD3<Double>) -> SIMD3<Double>? {
        func det(_ a: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>) -> Double {
            let first: Double = a.x * (c.y * d.z - c.z * d.y)
            let second: Double = c.x * (a.y * d.z - a.z * d.y)
            let third: Double = d.x * (a.y * c.z - a.z * c.y)
            return first - second + third
        }
        let whole = det(columns[0], columns[1], columns[2])
        guard abs(whole) > 1e-9 else { return nil }
        let x = det(b, columns[1], columns[2]) / whole
        let y = det(columns[0], b, columns[2]) / whole
        let z = det(columns[0], columns[1], b) / whole
        return SIMD3<Double>(x, y, z)
    }

    /// The same as the kernel, for one working-space color (tests and the help pictures' check).
    static func apply(_ c: SIMD3<Double>, settings: DevelopSettings) -> SIMD3<Double> {
        var color = c
        if let rows = matrix(settings) {
            color = SIMD3<Double>((rows[0] * c).sum(), (rows[1] * c).sum(), (rows[2] * c).sum())
        }
        let tint = settings[.calibrationShadowsTint] / 100
        guard tint != 0 else { return color }
        let y: Double = 0.2627 * color.x + 0.6780 * color.y + 0.0593 * color.z
        let weight = shadowWeight(y)
        let shift = SIMD3<Double>(0.5, -1, 0.5) * (tint * maxTint * weight)
        var tinted = color * (SIMD3<Double>(1, 1, 1) + shift)
        let newY: Double = 0.2627 * tinted.x + 0.6780 * tinted.y + 0.0593 * tinted.z
        if newY > 1e-6 { tinted *= y / newY }
        return tinted
    }

    /// How much of Shadows Tint a linear brightness gets: full in black, half around 4% (deep
    /// shadows), nothing from about 30% (midtones) up.
    static func shadowWeight(_ y: Double) -> Double {
        let lightness = cbrt(max(y, 0))
        let t = min(max(lightness / 0.68, 0), 1)
        let fade = 1 - t * t * (3 - 2 * t)
        return fade
    }

    /// The photo with Calibration applied; unchanged when it is neutral or the kernel didn't build.
    static func apply(_ image: CIImage, settings: DevelopSettings) -> CIImage {
        let tint = settings[.calibrationShadowsTint] / 100
        let rows = matrix(settings)
        guard rows != nil || tint != 0, let kernel else { return image }
        let identity: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        var arguments: [Any] = [image]
        for row in rows ?? identity {
            arguments.append(CIVector(x: CGFloat(row.x), y: CGFloat(row.y), z: CGFloat(row.z)))
        }
        arguments.append(Float(tint * maxTint))
        return kernel.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: arguments)?
            .cropped(to: image.extent) ?? image
    }

    /// Whether the kernel built, for tests.
    static var kernelAvailable: Bool { kernel != nil }

    private static let kernel: CIKernel? = RuntimeKernels.build("""
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        // r0...r2: the primaries' matrix as rows. tint: Shadows Tint × its strength.
        [[stitchable]] float4 atelierCalibration(coreimage::sampler image, float3 r0, float3 r1, float3 r2, float tint,
                                                 coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            float3 c = float3(dot(r0, color.rgb), dot(r1, color.rgb), dot(r2, color.rgb));
            if (tint != 0.0) {
                float3 luma = float3(0.2627, 0.6780, 0.0593);
                float y = dot(c, luma);
                float t = clamp(pow(max(y, 0.0), 1.0 / 3.0) / 0.68, 0.0, 1.0);
                float weight = 1.0 - t * t * (3.0 - 2.0 * t);
                float3 tinted = c * (1.0 + float3(0.5, -1.0, 0.5) * (tint * weight));
                float newY = dot(tinted, luma);
                c = newY > 1e-6 ? tinted * (y / newY) : tinted;
            }
            return float4(c, color.a);
        }
        """)?["atelierCalibration"]
}
