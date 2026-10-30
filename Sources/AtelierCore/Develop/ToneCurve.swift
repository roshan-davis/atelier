import CoreImage
import Foundation

/// Applies a tone curve to color without shifting hue, the way Adobe's DNG reference renderer
/// does (`RefBaselineRGBTone`): the curve moves the largest and smallest of R, G and B, and
/// the middle one is placed between them in the same proportion as before. Applying the
/// curve to each channel on its own pulls a saturated color's channels apart, so an orange
/// drifts toward red or yellow and gets more saturated as Contrast rises.
///
/// Works in sRGB-encoded values, like the rest of the tone curve. Outside 0...1 (colors
/// beyond sRGB, or brighter than white) the curve continues with slope 1.
enum ToneCurve {
    /// `lut` is the curve's output for evenly spaced inputs from 0 to 1. `refine` is Lightroom's
    /// Refine Saturation (0...1): at 1 the curve changes saturation along with brightness, as
    /// above; at 0 it changes brightness only, scaling each color as a whole.
    static func apply(_ lut: [Float], to image: CIImage, refine: Double = 1) -> CIImage {
        guard lut.count >= 2, let kernel = kernels?["atelierHueCurve"] else { return image }
        var pixels = [Float]()
        pixels.reserveCapacity(lut.count * 4)
        for value in lut { pixels += [value, value, value, 1] }
        return run(kernel, table: pixels, count: lut.count, on: image, extra: [Float(min(1, max(0, refine)))])
    }

    /// The Red, Green and Blue curves, each on its own channel. `lut` holds red, green and blue
    /// outputs for evenly spaced inputs from 0 to 1. Unlike Core Image's color curves, values
    /// outside 0...1 continue with slope 1 instead of being cut off.
    static func applyChannels(_ lut: [Float], to image: CIImage) -> CIImage {
        let count = lut.count / 3
        guard count >= 2, let kernel = kernels?["atelierChannelCurves"] else { return image }
        var pixels = [Float]()
        pixels.reserveCapacity(count * 4)
        for i in 0..<count { pixels += [lut[i * 3], lut[i * 3 + 1], lut[i * 3 + 2], 1] }
        return run(kernel, table: pixels, count: count, on: image, extra: [])
    }

    private static func run(_ kernel: CIKernel, table pixels: [Float], count: Int, on image: CIImage,
                            extra: [Any]) -> CIImage {
        let extent = image.extent
        let data = pixels.withUnsafeBytes { Data($0) }
        let table = CIImage(bitmapData: data, bytesPerRow: count * 16,
                            size: CGSize(width: count, height: 1), format: .RGBAf, colorSpace: nil)
        guard let encoded = image.matchedFromWorkingSpace(to: DevelopRenderer.sRGB) else { return image }
        let arguments: [Any] = [encoded, table, Float(count)] + extra
        guard let curved = kernel.apply(extent: extent, roiCallback: { index, rect in index == 1 ? table.extent : rect },
                                        arguments: arguments) else { return image }
        return curved.matchedToWorkingSpace(from: DevelopRenderer.sRGB) ?? image
    }

    /// Whether the kernels built, for tests.
    static var kernelAvailable: Bool { kernels != nil }

    private static let kernels: [String: CIKernel]? = RuntimeKernels.build("""
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        static float atelierCurve(coreimage::sampler table, float count, float x) {
            float lo = table.sample(table.transform(float2(0.5, 0.5))).r;
            float hi = table.sample(table.transform(float2(count - 0.5, 0.5))).r;
            if (x <= 0.0) { return lo + x; }
            if (x >= 1.0) { return hi + (x - 1.0); }
            return table.sample(table.transform(float2(0.5 + x * (count - 1.0), 0.5))).r;
        }

        [[stitchable]] float4 atelierHueCurve(coreimage::sampler image, coreimage::sampler table, float count,
                                              float refine, coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            float3 c = color.rgb;
            float high = max(c.r, max(c.g, c.b));
            float low = min(c.r, min(c.g, c.b));
            float newHigh = atelierCurve(table, count, high);
            float newLow = atelierCurve(table, count, low);
            float3 result;
            if (high - low < 1e-6) {
                result = float3(newHigh);
            } else {
                // Every channel keeps its place between the smallest and the largest.
                result = newLow + (c - low) * ((newHigh - newLow) / (high - low));
            }
            if (refine < 1.0) {
                // Brightness only: the whole color scaled by what the curve does to its luma.
                float y = dot(c, float3(0.2126, 0.7152, 0.0722));
                float newY = atelierCurve(table, count, y);
                float3 flat = y > 1e-4 ? c * (newY / y) : c + (newY - y);
                result = mix(flat, result, refine);
            }
            return float4(result, color.a);
        }

        [[stitchable]] float4 atelierChannelCurves(coreimage::sampler image, coreimage::sampler table, float count,
                                                   coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            float4 lo = table.sample(table.transform(float2(0.5, 0.5)));
            float4 hi = table.sample(table.transform(float2(count - 0.5, 0.5)));
            float3 result;
            for (int i = 0; i < 3; i++) {
                float x = color[i];
                if (x <= 0.0) {
                    result[i] = lo[i] + x;
                } else if (x >= 1.0) {
                    result[i] = hi[i] + (x - 1.0);
                } else {
                    result[i] = table.sample(table.transform(float2(0.5 + x * (count - 1.0), 0.5)))[i];
                }
            }
            return float4(result, color.a);
        }
        """)
}
