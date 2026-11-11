import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Refine Edge's guided filter (He, Sun and Tang, 2013) for AI selections: the mask is redrawn
/// as a * I + b in every window, with I the photo's brightness, so its edge moves onto the
/// photo's own edges. Our own kernels, like Dehaze's, instead of Core Image's CIGuidedFilter,
/// which emptied the selection (Rosh, Nov 10, 2026: Refine Edge above 0 removed it).
///
/// Worked out on a copy at most 2048 pixels long (the fast guided filter: coefficients
/// smoothed there, then applied with the full-size brightness), so it is quick at any size and
/// the preview and an export match.
enum MaskGuidedFilter {
    static let workingSize = 2048.0

    /// The mask refined with `guide` (the photo, linear working space, same frame). `radius` is
    /// in full-size pixels; `epsilon` (on 0...1 brightness) is how strongly an edge must show
    /// in the photo to be followed: smaller follows weaker edges. Nil when the kernels didn't
    /// build.
    static func apply(mask: CIImage, guide: CIImage, radius: Double, epsilon: Double, extent: CGRect) -> CIImage? {
        guard let kernels, !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { return nil }
        let s = min(1, workingSize / Double(max(extent.width, extent.height)))
        let toSmall = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
        let smallExtent = CGRect(x: 0, y: 0, width: extent.width * s, height: extent.height * s).integral
        func small(_ image: CIImage) -> CIImage {
            image.clampedToExtent().transformed(by: toSmall).cropped(to: smallExtent)
        }
        func kernel(_ name: String, _ arguments: [Any], _ area: CGRect) -> CIImage? {
            kernels[name]?.apply(extent: area, roiCallback: { _, rect in rect }, arguments: arguments)
        }
        let boxRadius = Float(max(1, radius * s))
        func box(_ image: CIImage) -> CIImage {
            let filter = CIFilter.boxBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = boxRadius
            return filter.outputImage?.cropped(to: smallExtent) ?? image
        }
        let guideSmall = small(guide), maskSmall = small(mask)
        guard let packed = kernel("atelierMaskGuidePack", [guideSmall, maskSmall, 0.0], smallExtent),
              let product = kernel("atelierMaskGuidePack", [guideSmall, maskSmall, 1.0], smallExtent),
              let raw = kernel("atelierMaskGuideCoefficients", [box(packed), box(product), epsilon], smallExtent)
        else { return nil }
        let coefficients = box(raw).clampedToExtent().transformed(by: toSmall.inverted())
        return kernel("atelierMaskGuideApply", [guide.clampedToExtent(), coefficients], extent)
    }

    /// Whether the kernels built, for tests.
    static var kernelsAvailable: Bool { kernels != nil }

    private static let kernels: [String: CIKernel]? = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            // Brightness as seen (gamma 2.2) so shadows have edges too, 0...1.
            static float atelierMaskGuideBrightness(coreimage::sampler s, float2 p) {
                float3 c = s.sample(s.transform(p)).rgb;
                float l = clamp(dot(c, float3(0.2627, 0.6780, 0.0593)), 0.0, 1.0);
                return pow(l, 1.0 / 2.2);
            }

            // mode 0: (I, p, I*I); mode 1: (I*p).
            [[stitchable]] float4 atelierMaskGuidePack(coreimage::sampler guide, coreimage::sampler mask, float mode,
                                                       coreimage::destination dest) {
                float2 p = dest.coord();
                float i = atelierMaskGuideBrightness(guide, p);
                float m = clamp(mask.sample(mask.transform(p)).r, 0.0, 1.0);
                if (mode > 0.5) { return float4(i * m, 0.0, 0.0, 1.0); }
                return float4(i, m, i * i, 1.0);
            }

            // The mask is a * I + b in each window.
            [[stitchable]] float4 atelierMaskGuideCoefficients(coreimage::sampler means, coreimage::sampler product,
                                                               float eps, coreimage::destination dest) {
                float2 p = dest.coord();
                float3 m = means.sample(means.transform(p)).rgb;
                float ip = product.sample(product.transform(p)).r;
                float a = (ip - m.r * m.g) / (max(m.b - m.r * m.r, 0.0) + eps);
                return float4(a, m.g - a * m.r, 0.0, 1.0);
            }

            [[stitchable]] float4 atelierMaskGuideApply(coreimage::sampler guide, coreimage::sampler coefficients,
                                                        coreimage::destination dest) {
                float2 p = dest.coord();
                float2 ab = coefficients.sample(coefficients.transform(p)).rg;
                float q = clamp(ab.x * atelierMaskGuideBrightness(guide, p) + ab.y, 0.0, 1.0);
                return float4(q, q, q, 1.0);
            }
            """
        return RuntimeKernels.build(source)
    }()
}
