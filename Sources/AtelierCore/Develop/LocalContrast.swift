import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Presence > Clarity and Texture: local contrast on luminance, as Lightroom's are.
///
/// The photo's brightness (perceptual, gamma 2.2) is split into a smooth base and the detail
/// on top of it. The base comes from a guided filter (He, Sun and Tang, 2013) guided by the
/// brightness itself, so it follows strong edges instead of blurring across them: boosting
/// the detail adds no halos, and lowering it smooths surfaces without softening edges, so
/// negative values look smooth rather than out of focus. Only brightness changes; each pixel's
/// color keeps its hue and saturation.
///
/// Clarity works on wide areas and is weighted toward the midtones, so it doesn't clip
/// highlights or crush shadows. Texture works on medium-sized detail (skin, bark, foliage).
/// Radii are in full-size photo pixels, so the live proxy, a crop and an export all match.
enum LocalContrast {
    struct Kind {
        /// Window radius in full-size pixels.
        let radius: Double
        /// Edges with more contrast than about the square root of this stay in the base.
        let edge: Double
        /// Detail gain at ±100.
        let strength: Double
        let midtones: Bool
    }

    static let clarity = Kind(radius: 70, edge: 0.01, strength: 0.9, midtones: true)
    static let texture = Kind(radius: 15, edge: 0.003, strength: 1.0, midtones: false)

    /// `amount` is -1...1; `scale` the render's size relative to the full photo.
    static func apply(_ image: CIImage, amount: Double, kind: Kind, scale: Double) -> CIImage {
        let extent = image.extent
        guard amount != 0, !extent.isInfinite, let kernels else { return image }
        let radius = max(1, kind.radius * scale)
        func pixelwise(_ name: String, _ arguments: [Any]) -> CIImage? {
            kernels[name]?.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: arguments)
        }
        func box(_ input: CIImage) -> CIImage {
            let filter = CIFilter.boxBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(radius)
            return filter.outputImage?.cropped(to: extent) ?? input
        }
        guard let moments = pixelwise("atelierLocalMoments", [image]),
              let coefficients = pixelwise("atelierLocalCoefficients", [box(moments), kind.edge]) else { return image }
        return pixelwise("atelierLocalContrast", [image, box(coefficients), kind.strength * amount,
                                                  kind.midtones ? 1.0 : 0.0]) ?? image
    }

    static var kernelsAvailable: Bool { kernels != nil }

    private static let kernels: [String: CIKernel]? = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            static float atelierGammaLuma(float3 c) {
                return pow(max(dot(c, float3(0.2627, 0.6780, 0.0593)), 0.0), 1.0 / 2.2);
            }

            // The brightness and its square, for the guided filter's local mean and variance.
            [[stitchable]] float4 atelierLocalMoments(coreimage::sampler image, coreimage::destination dest) {
                float g = atelierGammaLuma(image.sample(image.transform(dest.coord())).rgb);
                return float4(g, g * g, 0.0, 1.0);
            }

            // Guided filter: in each window the base is a * g + b; a is near 1 on strong edges.
            [[stitchable]] float4 atelierLocalCoefficients(coreimage::sampler moments, float edge,
                                                           coreimage::destination dest) {
                float2 m = moments.sample(moments.transform(dest.coord())).rg;
                float variance = max(m.y - m.x * m.x, 0.0);
                float a = variance / (variance + edge);
                return float4(a, m.x - a * m.x, 0.0, 1.0);
            }

            [[stitchable]] float4 atelierLocalContrast(coreimage::sampler image, coreimage::sampler coefficients,
                                                       float gain, float midtones, coreimage::destination dest) {
                float2 p = dest.coord();
                float4 color = image.sample(image.transform(p));
                float2 ab = coefficients.sample(coefficients.transform(p)).rg;
                float luma = max(dot(color.rgb, float3(0.2627, 0.6780, 0.0593)), 0.0);
                float g = pow(luma, 1.0 / 2.2);
                float detail = g - (ab.x * g + ab.y);
                float w = midtones > 0.5 ? sqrt(clamp(4.0 * g * (1.0 - g), 0.0, 1.0)) : clamp(4.0 * g, 0.0, 1.0);
                float g2 = max(g + gain * detail * w, 0.0);
                float newLuma = pow(g2, 2.2);
                float3 rgb = luma > 1e-4 ? color.rgb * (newLuma / luma) : color.rgb + (newLuma - luma);
                return float4(rgb, color.a);
            }
            """
        guard let built = try? CIKernel.kernels(withMetalString: source), built.count == 3 else { return nil }
        return Dictionary(built.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }()
}
