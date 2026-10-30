import CoreImage
import Foundation

/// Effects > Glow: light spilling from the bright parts of the photo, as Camera Raw's Glow and
/// Luminar's Glow do. Range sets how bright a tone must be to glow, Spread how far the light
/// reaches, Warmth its color.
///
/// - Diffusion: a soft, dreamy haze over the whole photo, like a diffusion filter.
/// - Bloom: highlights spill light onto what is around them.
/// - Halation: the red-orange glow film shows around bright highlights, where light passed
///   through the emulsion, reflected off the film base and exposed the red layer again. Strongest
///   where a highlight meets a darker area, as on cinema film (CineStill 800T).
///
/// Spread is a share of the photo's size, so the live proxy and an export look the same.
enum Glow {
    static func apply(_ image: CIImage, settings: DevelopSettings, extent: CGRect) -> CIImage {
        guard let kernels, let source = kernels["atelierGlowSource"], let combine = kernels["atelierGlowCombine"]
        else { return image }
        let style = settings.glowStyle
        let range = settings[.glowRange] / 100
        // Diffusion takes most of the tones; Bloom and Halation only the bright ones.
        let low = style == .diffusion ? 0.55 * (1 - range) : 0.95 - 0.5 * range
        let threshold = CIVector(x: low, y: min(1, low + 0.25))
        guard let bright = source.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [image, threshold])
        else { return image }
        let longEdge = Double(max(extent.width, extent.height))
        let sigma = longEdge * (0.003 + 0.03 * settings[.glowSpread] / 100)
        let glow = bright.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let params = CIVector(x: settings[.glowAmount] / 100, y: Double(style.rawValue),
                              z: settings[.glowWarmth] / 100, w: 0)
        return combine.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [image, glow, params])?
            .cropped(to: extent) ?? image
    }

    /// Whether the kernels built, for tests.
    static var kernelAvailable: Bool { kernels != nil }

    private static let kernels: [String: CIKernel]? = RuntimeKernels.build("""
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        static float atelierGlowLuma(float3 c) {
            return pow(max(dot(c, float3(0.2627, 0.6780, 0.0593)), 0.0), 1.0 / 2.2);
        }

        // The tones that glow: those above the threshold, faded in over its width.
        [[stitchable]] float4 atelierGlowSource(coreimage::sampler image, float2 threshold, coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            float w = smoothstep(threshold.x, threshold.y, atelierGlowLuma(color.rgb));
            return float4(max(color.rgb, float3(0.0)) * w, color.a);
        }

        // params: amount (0...1), style (0 Diffusion, 1 Bloom, 2 Halation), warmth (-1...1).
        [[stitchable]] float4 atelierGlowCombine(coreimage::sampler image, coreimage::sampler glow, float4 params,
                                                 coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            float3 base = color.rgb;
            float3 light = max(glow.sample(glow.transform(dest.coord())).rgb, float3(0.0));
            float amount = params.x;
            int style = int(params.y + 0.5);
            float warmth = params.z;
            float3 tint = float3(1.0 + 0.3 * max(warmth, 0.0), 1.0 + 0.05 * warmth, 1.0 - 0.4 * max(warmth, 0.0) + 0.3 * max(-warmth, 0.0));
            tint.r -= 0.3 * max(-warmth, 0.0);
            float3 result;
            if (style == 0) {
                // A lighten blend toward the softened photo.
                result = mix(base, max(base, light * tint), amount * 0.7);
            } else if (style == 1) {
                result = base + light * tint * amount * 1.2;
            } else {
                // Red-orange, and mostly where the photo is darker than the light reaching it.
                float3 red = float3(1.0, 0.3, 0.1) * tint;
                float room = 1.0 - smoothstep(0.55, 1.0, atelierGlowLuma(base));
                result = base + light * red * amount * 1.5 * room;
            }
            return float4(result, color.a);
        }
        """)
}
