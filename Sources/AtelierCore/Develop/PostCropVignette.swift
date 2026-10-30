import CoreImage
import Foundation

/// Effects > Post-Crop Vignetting, modeled on Lightroom's: Style, Amount, Midpoint, Roundness,
/// Feather and Highlights, around the cropped photo.
///
/// The shape follows the crop: at Roundness 0 it is an ellipse with the crop's proportions
/// (Core Image's vignette was a circle, so a 3:2 crop darkened its sides more than its top and
/// bottom). Positive Roundness turns it toward a circle, negative toward a rounded rectangle.
/// Midpoint moves the edge of the effect outward, Feather softens it.
///
/// - Highlight Priority (the default) darkens like lower exposure but holds back bright tones
///   channel by channel, so highlights keep their punch (colors can shift a little).
/// - Color Priority darkens every channel alike, keeping hues; highlights darken more.
/// - Paint Overlay mixes the corners toward black or white: flat and soft.
///
/// Highlights (darkening with Highlight or Color Priority only) brings bright areas back.
enum PostCropVignette {
    static func apply(_ image: CIImage, settings: DevelopSettings, extent: CGRect) -> CIImage {
        guard let kernel = kernels?["atelierPostCropVignette"] else { return image }
        let frame = CIVector(x: extent.midX, y: extent.midY, z: max(1, extent.width / 2), w: max(1, extent.height / 2))
        let look = CIVector(x: settings.vignette / 100, y: settings.vignetteMidpoint / 100,
                            z: settings[.vignetteRoundness] / 100, w: settings[.vignetteFeather] / 100)
        let extra = CIVector(x: settings[.vignetteHighlights] / 100, y: Double(settings.vignetteStyle.rawValue))
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [image, frame, look, extra])?
            .cropped(to: extent) ?? image
    }

    /// Whether the kernel built, for tests.
    static var kernelAvailable: Bool { kernels != nil }

    private static let kernels: [String: CIKernel]? = RuntimeKernels.build("""
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        // frame: center and half size. look: amount (-1...1), midpoint, roundness (-1...1), feather.
        // extra: highlights, style (0 Highlight Priority, 1 Color Priority, 2 Paint Overlay).
        [[stitchable]] float4 atelierPostCropVignette(coreimage::sampler image, float4 frame, float4 look, float2 extra,
                                                      coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            // -1...1 across the frame; the corners are at a distance of about 1.41.
            float2 d = (dest.coord() - frame.xy) / frame.zw;
            float roundness = look.z;
            float distance;
            if (roundness >= 0.0) {
                float2 circle = d * frame.zw / sqrt(frame.z * frame.w);
                distance = length(mix(d, circle, roundness));
            } else {
                float e = 2.0 + 6.0 * -roundness;
                float2 a = abs(d);
                distance = pow(pow(a.x, e) + pow(a.y, e), 1.0 / e) * pow(2.0, 0.5 - 1.0 / e);
            }
            float middle = 0.35 + 0.9 * look.y;
            float width = 0.05 + look.w;
            float v = smoothstep(middle - 0.5 * width, middle + 0.5 * width, distance);
            float amount = look.x;
            float3 c = max(color.rgb, float3(0.0));
            int style = int(extra.y + 0.5);
            float3 result;
            if (style == 2) {
                float3 encoded = pow(c, float3(1.0 / 2.2));
                float3 target = amount < 0.0 ? float3(0.0) : float3(1.0);
                result = pow(mix(encoded, target, abs(amount) * v * 0.9), float3(2.2));
            } else if (amount < 0.0) {
                float3 darker = c * exp2(2.5 * amount * v);
                if (style == 0) {
                    float protect = 0.6 + 0.4 * extra.x;
                    float3 encoded = pow(c, float3(1.0 / 2.2));
                    result = mix(darker, c, protect * smoothstep(float3(0.55), float3(1.0), encoded));
                } else {
                    float y = pow(max(dot(c, float3(0.2627, 0.6780, 0.0593)), 0.0), 1.0 / 2.2);
                    result = mix(darker, c, extra.x * smoothstep(0.55, 1.0, y));
                }
            } else {
                float3 encoded = pow(c, float3(1.0 / 2.2));
                result = pow(1.0 - (1.0 - encoded) * (1.0 - amount * v * 0.75), float3(2.2));
            }
            return float4(result, color.a);
        }
        """)
}
