import CoreImage
import Foundation

/// Positive Exposure on a JPEG, HEIC or TIFF: a soft shoulder instead of a hard clip, like the
/// highlight roll-off Adobe's exposure curve has (the DNG SDK's `dng_function_exposure_tone`).
/// A decoded file has nothing above white, so a plain gain would flatten every bright area
/// into the same white. Tones below the knee keep the exact gain; above it they approach
/// white without reaching it. RAW files get their roll-off from the RAW engine.
enum ExposureRolloff {
    /// Linear value where the shoulder starts (about 80% in sRGB-encoded terms).
    static let knee = 0.6

    /// Applies the shoulder to an image whose exposure gain was already applied, keeping each
    /// pixel's hue by scaling all three channels with its brightest one.
    static func apply(_ image: CIImage) -> CIImage {
        guard let kernel else { return image }
        return kernel.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: [image, knee]) ?? image
    }

    /// The shoulder for one value, for tests.
    static func shoulder(_ x: Double) -> Double {
        x <= knee ? x : knee + (1 - knee) * (1 - exp(-(x - knee) / (1 - knee)))
    }

    static var kernelAvailable: Bool { kernel != nil }

    private static let kernel: CIKernel? = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            [[stitchable]] float4 atelierExposureRolloff(coreimage::sampler image, float knee,
                                                         coreimage::destination dest) {
                float4 color = image.sample(image.transform(dest.coord()));
                float m = max(color.r, max(color.g, color.b));
                if (m <= knee) { return color; }
                float rolled = knee + (1.0 - knee) * (1.0 - exp(-(m - knee) / (1.0 - knee)));
                return float4(color.rgb * (rolled / m), color.a);
            }
            """
        return (try? CIKernel.kernels(withMetalString: source))?.first { $0.name == "atelierExposureRolloff" }
    }()
}
