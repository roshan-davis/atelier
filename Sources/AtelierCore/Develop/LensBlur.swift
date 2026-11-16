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
    /// The largest radius the gather works at, in a level's pixels.
    static let gatherRadius = 12.0
    /// Each level is this much smaller than the one before.
    static let levelStep = 3.0
    /// The most samples the gather takes per pixel.
    static let maxSamples = 112
    /// The softening before each level's gather, in its pixels (see `apply`).
    static let prefilter = 0.8

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
    static func apply(_ image: CIImage, depth: CIImage, settings: DevelopSettings, areas: CIImage? = nil) -> CIImage {
        guard isOn(settings), let kernels, let cocKernel = kernels["atelierLensBlurCoC"],
              let boostKernel = kernels["atelierLensBlurBoost"], let gather = kernels["atelierLensBlurGather"],
              let levelKernel = kernels["atelierLensBlurLevel"], let composite = kernels["atelierLensBlurComposite"],
              let spillKernel = kernels["atelierLensBlurSpill"] else { return image }
        let extent = image.extent
        let longEdge = Double(max(extent.width, extent.height))
        let maxRadius = settings[.lensBlurAmount] / 100 * maxRadiusShare * longEdge
        guard maxRadius >= 0.5, extent.width >= 2, extent.height >= 2 else { return image }
        let focus = focalRange(settings)
        let same: CIKernelROICallback = { _, rect in rect }
        let noAreas = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        guard let coc = cocKernel.apply(extent: extent, roiCallback: same,
                                        arguments: [depth, (areas ?? noAreas).clampedToExtent(),
                                                    CIVector(x: focus.near, y: focus.far, z: reach)]),
              let boosted = boostKernel.apply(extent: extent, roiCallback: same,
                                              arguments: [image, settings[.lensBlurBoost] / 100])
        else { return image }

        // The levels: the full-size photo, then copies a third, a ninth... the size, until the
        // largest blur fits the gather's radius on the smallest.
        let toOrigin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let shape = Double(bokeh(settings).rawValue), catEye = settings[.lensBlurCatEye] / 100
        var levels: [CIImage] = []
        var level = 0
        while true {
            let factor = pow(levelStep, -Double(level))
            let frame = CGRect(x: 0, y: 0, width: max(1, (extent.width * factor).rounded(.down)),
                               height: max(1, (extent.height * factor).rounded(.down)))
            func shrink(_ picture: CIImage) -> CIImage {
                let moved = picture.transformed(by: toOrigin)
                guard level > 0 else { return moved }
                return moved.clampedToExtent()
                    .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
                    .cropped(to: frame)
            }
            let radius = min(gatherRadius, maxRadius * factor)
            let samples = min(maxSamples, max(12, Int((Double.pi * radius * radius / 3.5).rounded())))
            let reachOut = CGFloat(radius + 2)
            let around: CIKernelROICallback = { _, rect in rect.insetBy(dx: -reachOut, dy: -reachOut) }
            // A pixel this level is never used for (its own blur belongs to coarser levels and it
            // isn't sharp enough to take spill) is skipped, in this level's pixels.
            let isLast = gatherRadius * pow(levelStep, Double(level)) >= maxRadius || level >= 5
            let cutoff = isLast ? 1e9 : 4 * pow(levelStep, Double(level + 1)) * factor
            let center = CIVector(x: frame.midX, y: frame.midY, z: 0.5 * hypot(frame.width, frame.height))
            // The gather's spiral samples about one point per 4 pixels, so fine texture (leaves,
            // bark) under it came out mottled, and a coarse level's upsizing made the mottle
            // large at 100%. Softening the colors by under a pixel first keeps the blur smooth
            // (checked on the redwoods photo at 100%, Nov 16, 2026).
            guard let blurred = gather.apply(extent: frame, roiCallback: around,
                                             arguments: [shrink(boosted).clampedToExtent().applyingGaussianBlur(sigma: prefilter),
                                                         shrink(coc).clampedToExtent(),
                                                         CIVector(x: radius, y: shape, z: catEye, w: Double(samples)),
                                                         center, CIVector(x: maxRadius * factor, y: cutoff)])
            else { return image }
            let placed = level == 0 ? blurred : blurred.cropped(to: frame).clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: extent.width / frame.width, y: extent.height / frame.height))
            levels.append(placed.transformed(by: toOrigin.inverted()).cropped(to: extent))
            if isLast { break }
            level += 1
        }

        // Each pixel's own blur, from the level that fits it (between two, mixed).
        var own = levels[0]
        for (index, next) in levels.enumerated().dropFirst() {
            guard let mixed = levelKernel.apply(extent: extent, roiCallback: same,
                                                arguments: [own, next, coc, CIVector(x: maxRadius, y: Double(index))])
            else { return image }
            own = mixed
        }
        // Sharp to blurred by its own blur, then the foreground spilling over it at every level.
        guard var result = composite.apply(extent: extent, roiCallback: same, arguments: [image, own, coc, maxRadius])
        else { return image }
        for blurred in levels {
            guard let spilled = spillKernel.apply(extent: extent, roiCallback: same,
                                                  arguments: [result, blurred, coc, maxRadius]) else { return image }
            result = spilled
        }
        return result.cropped(to: extent).insertingIntermediate(cache: true)
    }

    /// The Focus and Blur areas (AT-072's refine): every visible mask with Lens Focus, drawn on
    /// `base`'s frame, Focus strength in red and Blur strength in green (the strongest where
    /// areas overlap). Nil when no mask has Lens Focus, so photos without areas pay nothing.
    static func areas(_ settings: DevelopSettings, on base: CIImage, provider: MaskProvider?) -> CIImage? {
        let extent = base.extent
        var result: CIImage?
        for mask in settings.masks where !mask.isHidden {
            let strength = mask.lensFocusStrength
            guard strength.focus > 0 || strength.blur > 0,
                  let alpha = DevelopRenderer.maskImage(mask, base: base, provider: provider) else { continue }
            // The mask's gray, scaled into red (Focus) or green (Blur).
            let tinted = alpha.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: strength.focus, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: strength.blur, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).cropped(to: extent)
            result = result.map { DevelopRenderer.maximum($0, tinted) } ?? tinted
        }
        return result?.cropped(to: extent)
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

        // Which level a pixel's own blur (c, full-size pixels) comes from: level f = log3(c / 4),
        // so each level works at radii of about 4 to 12 of its pixels.
        static float atelierLensBlurLevelOf(float c) { return log(max(c, 0.001) / 4.0) / log(3.0); }

        // focus: near, far, reach. Signed blur: + behind the range, - in front, 0 inside. areas:
        // the Focus areas' strength in red (toward sharp), the Blur areas' in green (toward the
        // most blur, on the side the pixel is on; behind when it is in focus).
        [[stitchable]] float4 atelierLensBlurCoC(coreimage::sampler depth, coreimage::sampler areas, float3 focus,
                                                 coreimage::destination dest) {
            float d = depth.sample(depth.transform(dest.coord())).r;
            float c = clamp((d - focus.y) / focus.z, 0.0, 1.0) - clamp((focus.x - d) / focus.z, 0.0, 1.0);
            float2 a = clamp(areas.sample(areas.transform(dest.coord())).rg, 0.0, 1.0);
            c *= 1.0 - a.x;
            c = mix(c, c < 0.0 ? -1.0 : 1.0, a.y);
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
        // scale: the largest blur at this level (pixels), and the own blur past which this level
        // isn't used (skipped).
        [[stitchable]] float4 atelierLensBlurGather(coreimage::sampler color, coreimage::sampler coc, float4 params,
                                                    float3 frame, float2 scale, coreimage::destination dest) {
            float R = params.x;
            int shape = int(params.y + 0.5);
            float catEye = params.z;
            int count = int(params.w + 0.5);
            float2 p = dest.coord();
            float cp = coc.sample(coc.transform(p)).r;
            if (abs(cp) * scale.x >= scale.y) { return float4(0.0); }
            // Radii in this level's pixels: a blur past the gather's reach is cut to it.
            cp = sign(cp) * min(abs(cp) * scale.x, R) / R;
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
                cq = sign(cq) * min(abs(cq) * scale.x, R) / R;
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

        // Mixes in level `params.y` over the levels before it. params: largest blur (full-size
        // pixels), level.
        [[stitchable]] float4 atelierLensBlurLevel(coreimage::sampler finer, coreimage::sampler level,
                                                   coreimage::sampler coc, float2 params, coreimage::destination dest) {
            float4 a = finer.sample(finer.transform(dest.coord()));
            float4 b = level.sample(level.transform(dest.coord()));
            float c = abs(coc.sample(coc.transform(dest.coord())).r) * params.x;
            float w = clamp(atelierLensBlurLevelOf(c) - (params.y - 1.0), 0.0, 1.0);
            return float4(mix(a.rgb, b.rgb, w), 1.0);
        }

        // Sharp to blurred by the pixel's own blur (radius in full-size pixels).
        [[stitchable]] float4 atelierLensBlurComposite(coreimage::sampler sharp, coreimage::sampler blurred,
                                                       coreimage::sampler coc, float radius, coreimage::destination dest) {
            float4 s = sharp.sample(sharp.transform(dest.coord()));
            float4 b = blurred.sample(blurred.transform(dest.coord()));
            float c = abs(coc.sample(coc.transform(dest.coord())).r) * radius;
            float t = smoothstep(0.25, 1.0, c);
            return float4(mix(s.rgb, max(b.rgb, float3(0.0)), t), s.a);
        }

        // The foreground a level found spilling over a pixel that is sharp or nearly so.
        [[stitchable]] float4 atelierLensBlurSpill(coreimage::sampler current, coreimage::sampler level,
                                                   coreimage::sampler coc, float radius, coreimage::destination dest) {
            float4 s = current.sample(current.transform(dest.coord()));
            float4 b = level.sample(level.transform(dest.coord()));
            float c = abs(coc.sample(coc.transform(dest.coord())).r) * radius;
            float a = clamp(b.a, 0.0, 1.0) * (1.0 - smoothstep(0.25, 1.0, c));
            return float4(mix(s.rgb, max(b.rgb, float3(0.0)), a), s.a);
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
