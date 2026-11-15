import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd

/// The mask sliders with no global twin in the render (AT-068): Hue, Moiré and Defringe.
/// Each works on the whole photo; the mask decides where it shows, as with every mask slider.
enum MaskSliders {
    // MARK: Hue

    /// The working space (linear Rec. 2020) to Oklab's LMS and back, as rows.
    private static let toLMS: simd_double3x3 = {
        let rows = ColorRangeSpace.toLMS
        return simd_double3x3(rows: [rows[0], rows[1], rows[2]])
    }()
    private static let fromLMS: simd_double3x3 = toLMS.inverse

    /// One working-space color with its hue turned by `degrees` in Oklab: lightness and chroma
    /// stay, so a turn never brightens, darkens or dulls a color, and grays don't move.
    /// Positive turns red toward yellow, yellow toward green, green toward blue.
    static func turnHue(_ c: SIMD3<Double>, degrees: Double) -> SIMD3<Double> {
        let lin = toLMS * c
        let l = cbrt(lin.x), m = cbrt(lin.y), s = cbrt(lin.z)
        let okL: Double = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let okA: Double = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let okB: Double = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let angle = degrees * .pi / 180
        let a: Double = okA * cos(angle) - okB * sin(angle)
        let b: Double = okA * sin(angle) + okB * cos(angle)
        let l2: Double = okL + 0.3963377774 * a + 0.2158037573 * b
        let m2: Double = okL - 0.1055613458 * a - 0.0638541728 * b
        let s2: Double = okL - 0.0894841775 * a - 1.2914855480 * b
        return fromLMS * SIMD3<Double>(l2 * l2 * l2, m2 * m2 * m2, s2 * s2 * s2)
    }

    static func hue(_ image: CIImage, degrees: Double) -> CIImage {
        guard degrees != 0, let hueKernel else { return image }
        func vector(_ row: SIMD3<Double>) -> CIVector {
            CIVector(x: CGFloat(row.x), y: CGFloat(row.y), z: CGFloat(row.z))
        }
        let forward = toLMS.transpose, back = fromLMS.transpose
        let angle = degrees * .pi / 180
        let arguments: [Any] = [image,
                                vector(forward.columns.0), vector(forward.columns.1), vector(forward.columns.2),
                                vector(back.columns.0), vector(back.columns.1), vector(back.columns.2),
                                CIVector(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))]
        return hueKernel.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: arguments)?
            .cropped(to: image.extent) ?? image
    }

    /// Whether the Hue kernel built, for tests.
    static var hueKernelAvailable: Bool { hueKernel != nil }

    private static let hueKernel: CIKernel? = RuntimeKernels.build("""
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        // r0...r2: working space to Oklab's LMS, as rows; i0...i2 back. turn: (cos, sin) of the angle.
        [[stitchable]] float4 atelierMaskHue(coreimage::sampler image, float3 r0, float3 r1, float3 r2,
                                             float3 i0, float3 i1, float3 i2, float2 turn,
                                             coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            float3 c = color.rgb;
            float3 lms = float3(dot(r0, c), dot(r1, c), dot(r2, c));
            lms = sign(lms) * pow(abs(lms), float3(1.0 / 3.0));
            float okL = 0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z;
            float okA = 1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z;
            float okB = 0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z;
            float a = okA * turn.x - okB * turn.y;
            float b = okA * turn.y + okB * turn.x;
            float3 q = float3(okL + 0.3963377774 * a + 0.2158037573 * b,
                              okL - 0.1055613458 * a - 0.0638541728 * b,
                              okL - 0.0894841775 * a - 1.2914855480 * b);
            q = q * q * q;
            return float4(dot(i0, q), dot(i1, q), dot(i2, q), color.a);
        }
        """)?["atelierMaskHue"]

    // MARK: Moiré

    /// Takes color from a widely blurred copy and keeps the photo's own brightness, so the
    /// colored bands of moiré (fabric, screens, fine patterns) turn to their average color.
    /// Wider than Color noise reduction: moiré bands are many pixels across. `scale` is the
    /// render's size relative to the full photo.
    static func moire(_ image: CIImage, amount: Double, scale: Double) -> CIImage {
        guard amount > 0 else { return image }
        let extent = image.extent
        let sigma = max(1, 12 * scale * min(amount, 100) / 100)
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let blend = CIFilter.luminosityBlendMode()
        blend.inputImage = image
        blend.backgroundImage = blurred
        guard let output = blend.outputImage?.cropped(to: extent) else { return image }
        return DevelopRenderer.mix(image, output, amount: min(1, amount / 50))
    }

    // MARK: Defringe

    /// Atelier's Defringe (Lens Corrections) with both colors at the strength the slider asks
    /// for and the default purple and green hue ranges.
    static func defringe(_ image: CIImage, amount: Double, scale: Double) -> CIImage {
        guard amount > 0 else { return image }
        var local = DevelopSettings()
        for color in DevelopSettings.FringeColor.allCases {
            local[color.amount] = min(amount, 100) / 100 * 20
        }
        return Defringe.apply(image, settings: local, scale: scale)
    }
}
