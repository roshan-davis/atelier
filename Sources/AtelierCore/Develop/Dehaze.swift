import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Presence > Dehaze, with the dark channel prior (He, Sun and Tang, CVPR 2009).
///
/// Haze is modeled as the scene seen through a veil of airlight: I = J t + A (1 - t), where
/// A is the haze color and t (0...1) how much of the scene gets through. In haze-free
/// areas at least one color channel is dark, so the darkest channel in a neighborhood
/// estimates how much veil lies over it. Positive amounts remove that veil, negative ones
/// add more where the photo is already hazy. Dark, colorful areas carry little haze and
/// barely change, so nothing is crushed to black, and pixels brighter than the haze are
/// left alone, so highlights don't clip.
///
/// The haze map is worked out on a copy about 512 pixels long and refined with a guided
/// filter (He, Sun and Tang, 2013) using the photo's luminance as the guide, so it follows
/// edges at full size without halos. The small copy is the same at every render size, so
/// the live proxy and an export match.
enum Dehaze {
    /// Long edge of the copy the haze map is worked out on.
    static let workingSize = 512.0
    /// Dark channel neighborhood and guided filter radius, in working-copy pixels.
    static let patchRadius = 7.0
    static let filterRadius = 16.0
    /// How far the haze color is pulled toward gray (0 keeps it, 1 makes it neutral), so a
    /// colored light source can't tint the whole photo.
    static let airlightNeutral = 0.6

    /// Dehaze at `amount` -1...1 on an image in the linear working space.
    static func apply(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        guard amount != 0, !extent.isInfinite, extent.width >= 2, extent.height >= 2,
              let kernels = kernels else { return image }
        let longEdge = Double(max(extent.width, extent.height))
        let s = min(1, workingSize / longEdge)

        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = image
        scale.scale = Float(s)
        scale.aspectRatio = 1
        guard let small = scale.outputImage else { return image }
        let smallExtent = small.extent

        func pixelwise(_ name: String, _ arguments: [Any], extent: CGRect = smallExtent) -> CIImage? {
            kernels[name]?.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: arguments)
        }
        func minimum(_ input: CIImage) -> CIImage {
            let filter = CIFilter.morphologyMinimum()
            filter.inputImage = clamped(input)
            filter.radius = Float(patchRadius)
            return filter.outputImage?.cropped(to: smallExtent) ?? input
        }
        func box(_ input: CIImage) -> CIImage {
            let filter = CIFilter.boxBlur()
            filter.inputImage = clamped(input)
            filter.radius = Float(filterRadius)
            return filter.outputImage?.cropped(to: smallExtent) ?? input
        }
        func average(_ input: CIImage) -> CIImage? {
            let filter = CIFilter.areaAverage()
            filter.inputImage = input
            filter.extent = smallExtent
            return filter.outputImage?.clampedToExtent()
        }

        // Haze color: the average of the haziest areas (the highest dark channel), weighted steeply.
        guard let darkest = pixelwise("atelierDehazeMinChannel", [small]) else { return image }
        let darkChannel = minimum(darkest)
        let peakFilter = CIFilter.areaMaximum()
        peakFilter.inputImage = darkChannel
        peakFilter.extent = smallExtent
        guard let peak = peakFilter.outputImage?.clampedToExtent(),
              let weighted = pixelwise("atelierDehazeWeight", [small, darkChannel, peak, 0.0]),
              let weights = pixelwise("atelierDehazeWeight", [small, darkChannel, peak, 1.0]),
              let colorSum = average(weighted), let weightSum = average(weights) else { return image }
        let airlight: [Any] = [colorSum, weightSum, airlightNeutral]

        // Haze map: the dark channel of the photo relative to the haze color.
        guard let relative = pixelwise("atelierDehazeRelative", [small] + airlight) else { return image }
        let haze = minimum(relative)

        // Guided filter coefficients, smoothed and brought back to full size.
        guard let packed = pixelwise("atelierDehazePack", [small, haze, 0.0]),
              let product = pixelwise("atelierDehazePack", [small, haze, 1.0]),
              let raw = pixelwise("atelierDehazeCoefficients", [box(packed), box(product), 1e-3]) else { return image }
        let coefficients = box(raw).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / s, y: 1 / s))

        return pixelwise("atelierDehaze", [image, coefficients] + airlight + [amount], extent: extent) ?? image
    }

    /// Edge-extends the output of one of our kernels. Rendered first, because Core Image
    /// otherwise fuses the clamp into a runtime-built Metal kernel and drops the kernel's
    /// arguments, which aborts the app ("Argument count mismatch for program ci_clampRect_…").
    static func clamped(_ image: CIImage) -> CIImage {
        image.insertingIntermediate(cache: false).clampedToExtent()
    }

    /// Whether the kernels built, for tests.
    static var kernelsAvailable: Bool { kernels != nil }

    /// Built from Metal at run time, like Film Grain. Without them Dehaze is left off.
    private static let kernels: [String: CIKernel]? = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            static float3 atelierDehazeSample(coreimage::sampler s, float2 p) {
                return s.sample(s.transform(p)).rgb;
            }

            static float atelierDehazeLuma(float3 c) {
                return dot(c, float3(0.2627, 0.6780, 0.0593));
            }

            // The haze color from the weighted sums, pulled toward gray.
            static float3 atelierAirlight(coreimage::sampler colorSum, coreimage::sampler weightSum,
                                          float neutral, float2 p) {
                float3 a = atelierDehazeSample(colorSum, p) / max(atelierDehazeSample(weightSum, p).r, 1e-6);
                float l = atelierDehazeLuma(a);
                return max(mix(a, float3(l), neutral), float3(0.05));
            }

            [[stitchable]] float4 atelierDehazeMinChannel(coreimage::sampler image, coreimage::destination dest) {
                float3 c = atelierDehazeSample(image, dest.coord());
                float m = max(min(c.r, min(c.g, c.b)), 0.0);
                return float4(m, m, m, 1.0);
            }

            // mode 0: the color times its weight; mode 1: the weight alone.
            [[stitchable]] float4 atelierDehazeWeight(coreimage::sampler image, coreimage::sampler dark,
                                                      coreimage::sampler peak, float mode,
                                                      coreimage::destination dest) {
                float2 p = dest.coord();
                float w = pow(clamp(atelierDehazeSample(dark, p).r / max(atelierDehazeSample(peak, p).r, 1e-4),
                                    0.0, 1.0), 8.0);
                if (mode > 0.5) { return float4(w, w, w, 1.0); }
                return float4(atelierDehazeSample(image, p) * w, 1.0);
            }

            [[stitchable]] float4 atelierDehazeRelative(coreimage::sampler image, coreimage::sampler colorSum,
                                                        coreimage::sampler weightSum, float neutral,
                                                        coreimage::destination dest) {
                float2 p = dest.coord();
                float3 c = atelierDehazeSample(image, p) / atelierAirlight(colorSum, weightSum, neutral, p);
                float d = clamp(min(c.r, min(c.g, c.b)), 0.0, 1.0);
                return float4(d, d, d, 1.0);
            }

            // Guide I (luminance) and raw transmission p. mode 0: (I, p, I*I); mode 1: (I*p).
            [[stitchable]] float4 atelierDehazePack(coreimage::sampler image, coreimage::sampler haze, float mode,
                                                    coreimage::destination dest) {
                float2 p = dest.coord();
                float i = atelierDehazeLuma(atelierDehazeSample(image, p));
                float t = 1.0 - 0.95 * atelierDehazeSample(haze, p).r;
                if (mode > 0.5) { return float4(i * t, 0.0, 0.0, 1.0); }
                return float4(i, t, i * i, 1.0);
            }

            // Guided filter: t is a * I + b in each window.
            [[stitchable]] float4 atelierDehazeCoefficients(coreimage::sampler means, coreimage::sampler product,
                                                            float eps, coreimage::destination dest) {
                float2 p = dest.coord();
                float3 m = atelierDehazeSample(means, p);
                float ip = atelierDehazeSample(product, p).r;
                float a = (ip - m.r * m.g) / (m.b - m.r * m.r + eps);
                return float4(a, m.g - a * m.r, 0.0, 1.0);
            }

            [[stitchable]] float4 atelierDehaze(coreimage::sampler image, coreimage::sampler coefficients,
                                                coreimage::sampler colorSum, coreimage::sampler weightSum,
                                                float neutral, float amount, coreimage::destination dest) {
                float2 p = dest.coord();
                float4 color = image.sample(image.transform(p));
                float3 a = atelierAirlight(colorSum, weightSum, neutral, p);
                float2 ab = atelierDehazeSample(coefficients, p).rg;
                float t = clamp(ab.x * atelierDehazeLuma(color.rgb) + ab.y, 0.0, 1.0);
                float haze = 1.0 - t;
                float3 rgb;
                if (amount > 0.0) {
                    float te = max(1.0 - amount * haze, 0.15);
                    float3 clear = max(a + (color.rgb - a) / te, float3(0.0));
                    rgb = select(clear, color.rgb, color.rgb >= a);
                } else {
                    float k = -amount * (0.25 + 0.4 * haze);
                    rgb = mix(color.rgb, a, k);
                }
                return float4(rgb, color.a);
            }
            """
        guard let built = try? CIKernel.kernels(withMetalString: source), built.count == 6 else { return nil }
        return Dictionary(built.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }()
}
