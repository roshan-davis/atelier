import CoreImage
import Foundation

/// Lens Blur (AT-072), as in Lightroom: the photo blurred as a wide-open lens would blur it, more
/// the farther a part is from the Focal Range kept sharp, from the depth model's map (the one
/// Depth Range and Select Sky use).
///
/// - Blur Amount: how much the farthest parts blur, as a share of the photo's long edge, so the
///   live proxy and an export look the same.
/// - Bokeh: the shape bright out-of-focus points take (Circle, Bubble with a bright rim, 5-Blade,
///   Ring with a dark middle, Anamorphic ovals). Cat Eye cuts the shapes toward the photo's edges
///   into the swirl of an old lens. Boost brightens the out-of-focus highlights so they read as
///   bokeh, not gray.
/// - Focal Range: Near and Far on the photo's own depth (0 nearest, 100 farthest). The blur grows
///   with the distance from it in the model's relative inverse depth, which is how a lens's blur
///   grows, and in front of the range as well as behind it.
///
/// It runs on the uncropped, corrected photo in linear light before any tone or color step, so
/// highlights spread as light does, and masks still see the sharp photo. How:
/// 1. Each pixel's signed blur radius from its depth (in front of the range negative).
/// 2. The photo with Boost and the radii are shrunk until the largest radius is about 12 pixels
///    (Lanczos), so the cost doesn't grow with Blur Amount.
/// 3. A gather on the GPU: each pixel takes the samples of a spiral within 12 pixels whose own
///    blur shape reaches it (scatter as gather), weighted by the shape's light and by one over the
///    shape's area. Something behind a sharper pixel doesn't spill onto it; something in front
///    does, and how much of it did is kept as alpha.
/// 4. Back at full size, each pixel is mixed from sharp to blurred by its own radius and by the
///    foreground spilling over it, so in-focus edges stay as crisp as the photo.
public enum LensBlur {
    /// Lightroom's bokeh shapes, stored as `lensBlurBokeh`.
    public enum Bokeh: Int, CaseIterable, Sendable {
        case circle, bubble, fiveBlade, ring, anamorphic

        public var title: String {
            switch self {
            case .circle: return "Circle"
            case .bubble: return "Bubble"
            case .fiveBlade: return "5-Blade"
            case .ring: return "Ring"
            case .anamorphic: return "Anamorphic"
            }
        }

        /// What the shape looks like, for the panel's tooltip.
        public var detail: String {
            switch self {
            case .circle: return "Round and even, like a modern lens wide open"
            case .bubble: return "Round with a bright rim, like a soap bubble"
            case .fiveBlade: return "Five-sided, like a lens with a five-blade aperture"
            case .ring: return "Bright rings with a dark middle, like a mirror lens"
            case .anamorphic: return "Tall ovals, like an anamorphic cinema lens"
            }
        }
    }

    /// The largest blur, at Blur Amount 100, as a share of the photo's long edge.
    static let maxRadiusShare = 0.025
    /// The depth (relative inverse depth, 0...1 over the photo) at which the blur reaches its
    /// most, measured from the focal range.
    static let reach = 0.5
    /// The largest radius the gather works at; the photo is shrunk to fit it.
    static let gatherRadius = 12.0
    /// The most samples the gather takes per pixel.
    static let maxSamples = 112

    /// Whether Lens Blur changes the photo: Apply on, some Blur Amount, and something outside
    /// the focal range.
    public static func isOn(_ settings: DevelopSettings) -> Bool {
        let focus = focalRange(settings)
        return settings[.lensBlurApply] >= 0.5 && settings[.lensBlurAmount] > 0 && (focus.near > 0 || focus.far < 1)
    }

    /// The focal range on the 0...1 depth, near ≤ far.
    static func focalRange(_ settings: DevelopSettings) -> (near: Double, far: Double) {
        let a = settings[.lensBlurFocusNear] / 100, b = settings[.lensBlurFocusFar] / 100
        return (min(a, b), max(a, b))
    }

    public static func bokeh(_ settings: DevelopSettings) -> Bokeh {
        Bokeh(rawValue: Int(settings[.lensBlurBokeh].rounded())) ?? .circle
    }

    /// The signed blur at `depth` (0 nearest to 1 farthest), -1...1: negative in front of the
    /// focal range, positive behind it, 0 inside. The same as the CoC kernel, for tests.
    static func blur(atDepth depth: Double, near: Double, far: Double) -> Double {
        min(1, max(0, (depth - far) / reach)) - min(1, max(0, (near - depth) / reach))
    }

    /// The Focal Range that keeps `depths` (0 nearest to 1 farthest, as the depth model found
    /// them) sharp, in the 0...100 the sliders show: from the 10th to the 90th percentile, at
    /// least 4 apart, so a pick on a flat area isn't a single depth.
    public static func focalRange(for depths: [Float]) -> (near: Double, far: Double)? {
        let sorted = depths.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let low = Double(sorted[sorted.count / 10]), high = Double(sorted[(sorted.count - 1) * 9 / 10])
        let middle = (low + high) / 2
        let half = max((high - low) / 2, 0.02)
        let near = max(0, middle - half), far = min(1, middle + half)
        return ((near * 100).rounded(), (far * 100).rounded())
    }

    /// `image` (the corrected photo, linear) with the lens blur `settings` ask for, from `depth`
    /// (0 nearest to 1 farthest in red, on the same frame). The result is kept as a cached
    /// intermediate, so tone and color drags after it don't redo the blur.
    static func apply(_ image: CIImage, depth: CIImage, settings: DevelopSettings) -> CIImage {
        guard isOn(settings), let kernels, let cocKernel = kernels["atelierLensBlurCoC"],
              let boostKernel = kernels["atelierLensBlurBoost"], let gather = kernels["atelierLensBlurGather"],
              let composite = kernels["atelierLensBlurComposite"] else { return image }
        let extent = image.extent
        let longEdge = Double(max(extent.width, extent.height))
        let maxRadius = settings[.lensBlurAmount] / 100 * maxRadiusShare * longEdge
        guard maxRadius >= 0.5, extent.width >= 2, extent.height >= 2 else { return image }
        let focus = focalRange(settings)
        let same: CIKernelROICallback = { _, rect in rect }
        guard let coc = cocKernel.apply(extent: extent, roiCallback: same,
                                        arguments: [depth, CIVector(x: focus.near, y: focus.far, z: reach)]),
              let boosted = boostKernel.apply(extent: extent, roiCallback: same,
                                              arguments: [image, settings[.lensBlurBoost] / 100])
        else { return image }

        // Shrunk so the largest radius is the gather's.
        let factor = min(1, gatherRadius / maxRadius)
        let small = CGRect(x: 0, y: 0, width: max(1, (extent.width * factor).rounded(.down)),
                           height: max(1, (extent.height * factor).rounded(.down)))
        func shrink(_ picture: CIImage) -> CIImage {
            let moved = picture.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            guard factor < 1 else { return moved }
            return moved.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
                .cropped(to: small)
        }
        let radius = maxRadius * factor
        let samples = min(maxSamples, max(12, Int((Double.pi * radius * radius / 3.5).rounded())))
        let reachOut = CGFloat(radius + 2)
        let around: CIKernelROICallback = { _, rect in rect.insetBy(dx: -reachOut, dy: -reachOut) }
        let params = CIVector(x: radius, y: Double(bokeh(settings).rawValue), z: settings[.lensBlurCatEye] / 100,
                              w: Double(samples))
        let frame = CIVector(x: small.midX, y: small.midY, z: 0.5 * hypot(small.width, small.height))
        guard let blurred = gather.apply(extent: small, roiCallback: around,
                                         arguments: [shrink(boosted).clampedToExtent(), shrink(coc).clampedToExtent(),
                                                     params, frame])
        else { return image }

        // Back to full size, then sharp to blurred by each pixel's own blur and the foreground's.
        let upscaled = blurred.cropped(to: small).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / small.width, y: extent.height / small.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        guard let result = composite.apply(extent: extent, roiCallback: same, arguments: [image, upscaled, coc, radius])
        else { return image }
        return result.cropped(to: extent).insertingIntermediate(cache: true)
    }

    /// Visualize Depth: the depth in color, warm near to cool far as Lightroom shows it, with the
    /// focal range kept sharp drawn lighter. Linear, on `depth`'s frame.
    static func visualize(depth: CIImage, settings: DevelopSettings) -> CIImage? {
        guard let kernel = kernels?["atelierLensBlurDepthView"] else { return nil }
        let focus = focalRange(settings)
        return kernel.apply(extent: depth.extent, roiCallback: { _, rect in rect },
                            arguments: [depth, CIVector(x: focus.near, y: focus.far)])
    }

    /// Settings with Lens Blur on, for the warm-up (`PipelineWarmUp`), so the first Apply on a
    /// photo finds its programs built.
    static var warmUpSettings: DevelopSettings {
        var settings = DevelopSettings()
        settings[.lensBlurApply] = 1
        settings[.lensBlurAmount] = 100
        settings[.lensBlurCatEye] = 20
        return settings
    }

    /// A depth ramp for the warm-up: near at the bottom, far at the top of `extent`.
    static func warmUpDepth(_ extent: CGRect) -> CIImage {
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: extent.midX, y: extent.minY), "inputColor0": CIColor.black,
            "inputPoint1": CIVector(x: extent.midX, y: extent.maxY), "inputColor1": CIColor.white,
        ])?.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        return ramp.cropped(to: extent)
    }

    /// Whether the kernels built, for tests.
    static var kernelAvailable: Bool { kernels != nil }

    private static let kernels: [String: CIKernel]? = RuntimeKernels.build("""
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        // focus: near, far, reach. Signed blur: + behind the range, - in front, 0 inside.
        [[stitchable]] float4 atelierLensBlurCoC(coreimage::sampler depth, float3 focus, coreimage::destination dest) {
            float d = depth.sample(depth.transform(dest.coord())).r;
            float c = clamp((d - focus.y) / focus.z, 0.0, 1.0) - clamp((focus.x - d) / focus.z, 0.0, 1.0);
            return float4(c, c, c, 1.0);
        }

        // Boost: the brightest highlights (near clipping) brighter, so they spread as bright
        // bokeh. Only those: boosting every light tone turned sunlit wood into flat white blobs
        // (checked on the redwoods splash photo, Nov 15, 2026).
        [[stitchable]] float4 atelierLensBlurBoost(coreimage::sampler image, float boost, coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            float3 rgb = max(color.rgb, float3(0.0));
            float luma = pow(dot(rgb, float3(0.2627, 0.6780, 0.0593)), 1.0 / 2.2);
            return float4(rgb * (1.0 + 2.0 * boost * smoothstep(0.85, 1.0, luma)), 1.0);
        }

        // params: radius (pixels at this size), bokeh (0 Circle, 1 Bubble, 2 5-Blade, 3 Ring,
        // 4 Anamorphic), Cat Eye (0...1), samples. frame: the image's center and half diagonal.
        // Alpha out: the share of the light that came from something in front, spilling over.
        [[stitchable]] float4 atelierLensBlurGather(coreimage::sampler color, coreimage::sampler coc, float4 params,
                                                    float3 frame, coreimage::destination dest) {
            float R = params.x;
            int shape = int(params.y + 0.5);
            float catEye = params.z;
            int count = int(params.w + 0.5);
            float2 p = dest.coord();
            float cp = coc.sample(coc.transform(p)).r;
            float rp = abs(cp) * R;
            float selfWeight = 1.0 / max(rp * rp, 1.0);
            float3 sum = color.sample(color.transform(p)).rgb * selfWeight;
            float total = selfWeight;
            float spill = 0.0;
            float2 toEdge = (p - frame.xy) / frame.z;
            for (int i = 0; i < count; i++) {
                float r = R * sqrt((float(i) + 0.5) / float(count));
                float angle = float(i) * 2.39996323;
                float2 o = r * float2(cos(angle), sin(angle));
                float2 q = p + o;
                float cq = coc.sample(coc.transform(q)).r;
                // Something farther than this pixel blurs onto it no more than this pixel blurs.
                float reach = (cq > cp ? min(abs(cq), abs(cp)) : abs(cq)) * R;
                float2 d = -o;
                float limit = 1.0;
                if (shape == 2) {
                    float segment = 1.2566371;
                    float t = fmod(atan2(d.x, d.y) + 6.2831853, segment) - 0.5 * segment;
                    limit = 0.80901699 / cos(t);
                } else if (shape == 4) {
                    float2 n = d / max(r, 0.0001);
                    limit = rsqrt((n.x / 0.55) * (n.x / 0.55) + n.y * n.y);
                }
                float cover = clamp(reach * limit - r + 0.5, 0.0, 1.0);
                if (catEye > 0.0) {
                    float2 s = d + catEye * 0.7 * toEdge * reach;
                    cover *= clamp(reach - length(s) + 0.5, 0.0, 1.0);
                }
                if (cover <= 0.0) { continue; }
                float u = clamp(r / max(reach * limit, 0.001), 0.0, 1.0);
                float light = 1.0;
                if (shape == 1) { light = 0.55 + 0.9 * u * u * u * u; }
                else if (shape == 3) { light = 0.12 + smoothstep(0.55, 0.85, u); }
                float w = cover * light / max(reach * reach, 1.0);
                sum += color.sample(color.transform(q)).rgb * w;
                total += w;
                if (cq < cp - 0.02 && abs(cq) > abs(cp)) { spill += w; }
            }
            return float4(sum / total, spill / total);
        }

        // Sharp to blurred by the pixel's own blur (radius at the gather's size) and the
        // foreground spilling over it.
        [[stitchable]] float4 atelierLensBlurComposite(coreimage::sampler sharp, coreimage::sampler blurred,
                                                       coreimage::sampler coc, float radius, coreimage::destination dest) {
            float4 s = sharp.sample(sharp.transform(dest.coord()));
            float4 b = blurred.sample(blurred.transform(dest.coord()));
            float c = abs(coc.sample(coc.transform(dest.coord())).r) * radius;
            float t = max(smoothstep(0.25, 1.0, c), clamp(b.a, 0.0, 1.0));
            return float4(mix(s.rgb, max(b.rgb, float3(0.0)), t), s.a);
        }

        // Warm near (orange) to cool far (blue); the focal range lighter. focus: near, far.
        [[stitchable]] float4 atelierLensBlurDepthView(coreimage::sampler depth, float2 focus, coreimage::destination dest) {
            float d = clamp(depth.sample(depth.transform(dest.coord())).r, 0.0, 1.0);
            float3 nearColor = float3(1.0, 0.55, 0.12), middle = float3(0.62, 0.36, 0.72), farColor = float3(0.12, 0.32, 0.95);
            float3 c = d < 0.5 ? mix(nearColor, middle, d * 2.0) : mix(middle, farColor, d * 2.0 - 1.0);
            float inFocus = step(focus.x, d) * step(d, focus.y);
            c = mix(c * 0.8, float3(1.0), 0.55 * inFocus);
            return float4(pow(c, float3(2.2)), 1.0);
        }
        """)
}
