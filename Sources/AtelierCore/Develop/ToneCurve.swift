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
    /// `lut` is the curve's output for evenly spaced inputs from 0 to 1.
    static func apply(_ lut: [Float], to image: CIImage) -> CIImage {
        guard lut.count >= 2, let kernel else { return image }
        let extent = image.extent
        var pixels = [Float]()
        pixels.reserveCapacity(lut.count * 4)
        for value in lut { pixels += [value, value, value, 1] }
        let data = pixels.withUnsafeBytes { Data($0) }
        let table = CIImage(bitmapData: data, bytesPerRow: lut.count * 16,
                            size: CGSize(width: lut.count, height: 1), format: .RGBAf, colorSpace: nil)
        guard let encoded = image.matchedFromWorkingSpace(to: DevelopRenderer.sRGB),
              let curved = kernel.apply(extent: extent, roiCallback: { index, rect in index == 1 ? table.extent : rect },
                                        arguments: [encoded, table, Float(lut.count)]) else { return image }
        return curved.matchedToWorkingSpace(from: DevelopRenderer.sRGB) ?? image
    }

    /// Whether the kernel built, for tests.
    static var kernelAvailable: Bool { kernel != nil }

    private static let kernel: CIKernel? = {
        let source = """
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
                                                  coreimage::destination dest) {
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
                return float4(result, color.a);
            }
            """
        return (try? CIKernel.kernels(withMetalString: source))?.first { $0.name == "atelierHueCurve" }
    }()
}
