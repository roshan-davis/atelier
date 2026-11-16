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
    /// How far from a Focus area the depth isn't trusted, a share of the long edge (`withAreas`).
    static let areaMargin = 0.02
    /// The scale a Focus edge's detail is judged at, a share of the long edge (`withAreas`).
    static let detailShare = 0.003
    /// The scale at which a Focus edge is told apart as hair (many edges) or an outline (one),
    /// a share of the long edge (`withAreas`).
    static let hairShare = 0.01
    /// Levels of thirds the background's blur is filled in over, behind and around the areas.
    static let fillLevels = 6
    /// The most samples the gather takes per pixel.
    static let maxSamples = 112
    /// The softening before each level's gather, in its pixels (see `apply`).
    static let prefilter = 0.8

    /// Every slider Lens Blur reads (the render's Lens Blur cache keys on them).
    static let parameters: [DevelopSettings.Parameter] = [
        .lensBlurApply, .lensBlurAmount, .lensBlurBokeh, .lensBlurCatEye, .lensBlurBoost,
        .lensBlurFocusNear, .lensBlurFocusFar,
    ]

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
              let spillKernel = kernels["atelierLensBlurSpill"],
              let weighKernel = kernels["atelierLensBlurWeigh"] else { return image }
        let extent = image.extent
        let longEdge = Double(max(extent.width, extent.height))
        let maxRadius = settings[.lensBlurAmount] / 100 * maxRadiusShare * longEdge
        guard maxRadius >= 0.5, extent.width >= 2, extent.height >= 2 else { return image }
        let focus = focalRange(settings)
        let same: CIKernelROICallback = { _, rect in rect }
        let noAreas = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        guard let depthCoC = cocKernel.apply(extent: extent, roiCallback: same,
                                             arguments: [depth, noAreas.clampedToExtent(),
                                                         CIVector(x: focus.near, y: focus.far, z: reach)]),
              let boostFound = boostKernel.apply(extent: extent, roiCallback: same,
                                                 arguments: [image, settings[.lensBlurBoost] / 100])
        else { return image }
        // Every level, the level mix, the composite and each spill read the blur sizes, and every
        // level reads the boosted photo: render each once per frame instead of once per reader
        // (the areas' masks, Fine Edges included, sit under the blur sizes).
        let cocFound = areas.flatMap { withAreas(depthCoC, areas: $0, extent: extent) } ?? depthCoC
        let coc = cocFound.insertingIntermediate(cache: false)
        let boosted = boostFound.insertingIntermediate(cache: false)

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
            // What a level sees: only pixels that blur by about one of its pixels or more. A sharp
            // pixel (the subject in focus) shrunk into a coarse level spread its color into the
            // background's blur around it, a halo outside a sharp edge (Rosh's hat, Nov 16, 2026).
            // Weighted (color and blur times the weight, the weight in alpha) and divided back
            // out in the gather; level 0 keeps every pixel.
            let minimum = level == 0 ? -1.0 : maxRadius * factor
            func weighed(_ picture: CIImage, blurSizes: Bool) -> CIImage? {
                weighKernel.apply(extent: extent, roiCallback: same,
                                  arguments: [picture, coc, CIVector(x: minimum, y: blurSizes ? 1 : 0)])
            }
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
            guard let levelColor = weighed(boosted, blurSizes: false), let levelCoC = weighed(coc, blurSizes: true),
                  let blurred = gather.apply(extent: frame, roiCallback: around,
                                             arguments: [shrink(levelColor).clampedToExtent().applyingGaussianBlur(sigma: prefilter),
                                                         shrink(levelCoC).clampedToExtent(),
                                                         CIVector(x: radius, y: shape, z: catEye, w: Double(samples)),
                                                         center, CIVector(x: maxRadius * factor, y: cutoff)])
            else { return image }
            // Read twice (the level mix and the spill): rendered once, at the level's own size.
            let gathered = blurred.cropped(to: frame).insertingIntermediate(cache: false)
            let placed = level == 0 ? gathered : gathered.clampedToExtent()
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
        // Sharp to blurred by its own blur, then the sharp photo back through the Focus areas (a
        // layer mask), then the foreground spilling over it at every level.
        guard var result = composite.apply(extent: extent, roiCallback: same, arguments: [image, own, coc, maxRadius])
        else { return image }
        for blurred in levels {
            guard let spilled = spillKernel.apply(extent: extent, roiCallback: same,
                                                  arguments: [result, blurred, coc, maxRadius]) else { return image }
            result = spilled
        }
        return result.cropped(to: extent).insertingIntermediate(cache: true)
    }

    /// The Focus and Blur areas (AT-072's Refine, `DevelopSettings.lensBlurAreas`) drawn on
    /// `base`'s frame: Focus strength in red, Blur strength in green (the strongest where areas
    /// overlap). Hidden areas are left out. Nil when there are none, so photos without areas pay
    /// nothing.
    static func areas(_ settings: DevelopSettings, on base: CIImage, provider: MaskProvider?) -> CIImage? {
        let extent = base.extent
        var result: CIImage?
        for mask in settings.lensBlurAreas where !mask.isHidden {
            guard let role = mask.lensBlurRole else { continue }
            let strength = (focus: role == .focus ? mask.lensBlurStrength : 0,
                            blur: role == .blur ? mask.lensBlurStrength : 0)
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

    /// `areas` (Focus in red, Blur in green) drawn into memory once, as a half-float red-green
    /// image on the same extent, so the blur's passes read pixels instead of redrawing the masks.
    static func drawnOnce(_ areas: CIImage, context: CIContext) -> CIImage {
        let extent = areas.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return areas }
        let rowBytes = width * 4
        guard let data = NSMutableData(length: rowBytes * height) else { return areas }
        context.render(areas.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)),
                       toBitmap: data.mutableBytes, rowBytes: rowBytes,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGh, colorSpace: nil)
        return CIImage(bitmapData: data as Data, bytesPerRow: rowBytes, size: CGSize(width: width, height: height),
                       format: .RGh, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// The blur sizes with the Focus and Blur areas (`areas`: Focus in red, Blur in green), and
    /// each pixel's Focus strength in green for the gather and the composite.
    ///
    /// Where a Focus area's edge is detailed (hair: the mask changes within a few pixels) it
    /// works as a layer mask: its pixels take the background's blur, are left out of the gather
    /// and go back on top sharp through the area. Where it is smooth (a feathered gradient) it
    /// lowers the blur, as Lightroom's Focus brush does. The depth model sees a hair cloud as one
    /// near blob, gaps included, so close to a detailed edge (`areaMargin` of the long edge) the
    /// depth isn't trusted: what isn't in the area blurs at least as much as the background
    /// beyond. Blur areas take the blur of what is around them, or the most blur where that is
    /// sharp. Rosh, Nov 16, 2026: the gaps in hair stayed sharp, and a Blur area didn't match
    /// the background next to it.
    private static func withAreas(_ coc: CIImage, areas: CIImage, extent: CGRect) -> CIImage? {
        guard let kernels, let nearKernel = kernels["atelierLensBlurNearArea"],
              let detailKernel = kernels["atelierLensBlurDetail"], let edgesKernel = kernels["atelierLensBlurEdges"],
              let fillWeigh = kernels["atelierLensBlurFillWeigh"], let fillUp = kernels["atelierLensBlurFillUp"],
              let areaKernel = kernels["atelierLensBlurAreaCoC"] else { return nil }
        let same: CIKernelROICallback = { _, rect in rect }
        let toOrigin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let longEdge = max(extent.width, extent.height)
        // How detailed the Focus edge is: the mask against itself softened, spread a little.
        let sigma = max(1, detailShare * longEdge)
        let softened = areas.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        // How many edges the mask has around each pixel: about one along a hat's or a face's
        // outline, many across hair. Only hair-like edges get the near band below: along a single
        // outline the mask may sit a pixel or two inside the subject, and the band blurred that
        // sliver like the background, smearing the hat's color outward as a halo (Rosh, Nov 16).
        let hairSigma = max(1, hairShare * longEdge)
        guard let edgesFound = edgesKernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
                                                 arguments: [areas.clampedToExtent()]) else { return nil }
        let edges = edgesFound.clampedToExtent().applyingGaussianBlur(sigma: hairSigma).cropped(to: extent)
        guard let detailFound = detailKernel.apply(extent: extent, roiCallback: same,
                                                   arguments: [areas, softened, edges, hairSigma * 2.5066283])
        else { return nil }
        let detail = detailFound.clampedToExtent().applyingGaussianBlur(sigma: 2 * sigma).cropped(to: extent)
            .insertingIntermediate(cache: false)
        // Near a detailed, hair-like edge: grown by the margin on a copy where the margin is 8 pixels, softened.
        let margin = max(1, areaMargin * longEdge)
        let small = min(1, 8 / margin)
        guard let inArea = nearKernel.apply(extent: extent, roiCallback: same, arguments: [detail]) else { return nil }
        let smallFrame = CGRect(x: 0, y: 0, width: extent.width * small, height: extent.height * small)
        let grown = inArea.transformed(by: toOrigin).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: small, y: small))
            .cropped(to: smallFrame.insetBy(dx: -2 * margin * small, dy: -2 * margin * small))
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: margin * small])
            .applyingGaussianBlur(sigma: margin * small / 3)
            .transformed(by: CGAffineTransform(scaleX: 1 / small, y: 1 / small))
            .transformed(by: toOrigin.inverted()).cropped(to: extent)
            .insertingIntermediate(cache: false)
        // The blur sizes filled in from outside (the near band and the Blur areas): a weighted
        // pyramid of thirds, then back up, each level taking its own value where it has weight.
        guard let weighed = fillWeigh.apply(extent: extent, roiCallback: same, arguments: [coc, grown, areas])
        else { return nil }
        var pyramid: [CIImage] = [weighed.transformed(by: toOrigin)]
        var size = extent.size
        for _ in 0..<fillLevels {
            size = CGSize(width: max(1, (size.width / levelStep).rounded(.down)), height: max(1, (size.height / levelStep).rounded(.down)))
            guard let last = pyramid.last, size.width >= 2, size.height >= 2 else { break }
            pyramid.append(last.clampedToExtent().applyingGaussianBlur(sigma: 0.5 * levelStep)
                .transformed(by: CGAffineTransform(scaleX: size.width / last.extent.width, y: size.height / last.extent.height))
                .cropped(to: CGRect(origin: .zero, size: size)).insertingIntermediate(cache: false))
        }
        // The coarsest level on its own (no coarser one to fall back on), then back up.
        guard let coarsest = pyramid.last,
              var filled = fillUp.apply(extent: coarsest.extent, roiCallback: same,
                                        arguments: [coarsest, CIImage(color: .black).cropped(to: coarsest.extent)])
        else { return nil }
        for finer in pyramid.dropLast().reversed() {
            let up = filled.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: finer.extent.width / filled.extent.width,
                                                   y: finer.extent.height / filled.extent.height))
            guard let next = fillUp.apply(extent: finer.extent, roiCallback: same, arguments: [finer, up]) else { return nil }
            filled = next
        }
        let background = filled.transformed(by: toOrigin.inverted()).cropped(to: extent)
        return areaKernel.apply(extent: extent, roiCallback: same, arguments: [coc, background, grown, areas, detail])
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

    /// An areas image of one Focus strength (red) and Blur strength (green), exactly those values.
    /// A plain `CIColor(red:green:blue:)` is sRGB, which Core Image converts into the linear
    /// Rec. 2020 working space: its red 1 arrives as about 0.63 red and 0.07 green, a weak Focus
    /// area with a little Blur in it (why two Lens Blur tests failed on Rosh's Mac, Nov 16, 2026).
    static func areaColor(focus: Double, blur: Double) -> CIImage {
        guard let color = CIColor(red: focus, green: blur, blue: 0, alpha: 1, colorSpace: DevelopRenderer.workingSpace)
        else { return CIImage(color: CIColor(red: focus, green: blur, blue: 0)) }
        return CIImage(color: color)
    }

    /// Focus and Blur areas for the warm-up: Focus on the left third, Blur on the right third,
    /// so the areas' kernels (`withAreas`) are built too.
    static func warmUpAreas(_ extent: CGRect) -> CIImage {
        let third = extent.width / 3
        let focus = areaColor(focus: 1, blur: 0)
            .cropped(to: CGRect(x: extent.minX, y: extent.minY, width: third, height: extent.height))
        let blur = areaColor(focus: 0, blur: 1)
            .cropped(to: CGRect(x: extent.maxX - third, y: extent.minY, width: third, height: extent.height))
        return focus.composited(over: blur).composited(over: CIImage(color: .black)).cropped(to: extent)
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
            // Green is the Focus strength the areas add (atelierLensBlurAreaCoC); none here.
            return float4(c, 0.0, 0.0, 1.0);
        }

        // A level's input, weighted by whether the pixel blurs by about a level pixel or more
        // (params.x: the largest blur in this level's pixels; negative keeps every pixel).
        // params.y 0: the color times the weight, the weight in alpha; 1: the signed blur times
        // the weight in red, the weight in green. The gather divides the weight back out.
        [[stitchable]] float4 atelierLensBlurWeigh(coreimage::sampler image, coreimage::sampler coc, float2 params,
                                                   coreimage::destination dest) {
            float2 cf = coc.sample(coc.transform(dest.coord())).rg;
            float c = cf.x;
            // A Focus area's pixels (green) feed no level: they go back on top, sharp.
            float w = (params.x < 0.0 ? 1.0 : smoothstep(0.5, 1.5, abs(c) * params.x)) * (1.0 - clamp(cf.y, 0.0, 1.0));
            if (params.y > 0.5) { return float4(c * w, w, 0.0, 1.0); }
            float4 color = image.sample(image.transform(dest.coord()));
            return float4(color.rgb * w, w);
        }

        // How steeply a Focus area changes here (its gradient's length, per pixel).
        [[stitchable]] float4 atelierLensBlurEdges(coreimage::sampler areas, coreimage::destination dest) {
            float2 p = dest.coord();
            float dx = areas.sample(areas.transform(p + float2(1.0, 0.0))).r - areas.sample(areas.transform(p - float2(1.0, 0.0))).r;
            float dy = areas.sample(areas.transform(p + float2(0.0, 1.0))).r - areas.sample(areas.transform(p - float2(0.0, 1.0))).r;
            float g = 0.5 * length(float2(dx, dy));
            return float4(g, g, g, 1.0);
        }

        // How much a Focus area changes here against its softened self (red): a detailed edge
        // such as hair changes a lot within a few pixels, a feathered gradient hardly at all.
        // Green: that, only where the area is hair-like. `edges` is the gradient's length softened
        // at the hair scale; times `scale` (that scale times the square root of 2 pi) it counts
        // the edges crossed there: about 1 along a single outline, several across hair.
        [[stitchable]] float4 atelierLensBlurDetail(coreimage::sampler areas, coreimage::sampler softened,
                                                    coreimage::sampler edges, float scale, coreimage::destination dest) {
            float a = areas.sample(areas.transform(dest.coord())).r;
            float s = softened.sample(softened.transform(dest.coord())).r;
            float d = smoothstep(0.01, 0.05, abs(a - s));
            float hair = smoothstep(1.5, 3.0, edges.sample(edges.transform(dest.coord())).r * scale);
            return float4(d, d * hair, 0.0, 1.0);
        }

        // A detailed, hair-like Focus edge (its spread detail in green, times 3, over a half): 1,
        // else 0.
        [[stitchable]] float4 atelierLensBlurNearArea(coreimage::sampler detail, coreimage::destination dest) {
            float f = step(0.5, clamp(3.0 * detail.sample(detail.transform(dest.coord())).g, 0.0, 1.0));
            return float4(f, f, f, 1.0);
        }

        // The blur sizes weighted for filling in: weight 0 near a Focus area and in Blur areas.
        // Out: blur times weight, weight.
        [[stitchable]] float4 atelierLensBlurFillWeigh(coreimage::sampler coc, coreimage::sampler near,
                                                       coreimage::sampler areas, coreimage::destination dest) {
            float c = coc.sample(coc.transform(dest.coord())).r;
            float n = clamp(near.sample(near.transform(dest.coord())).r, 0.0, 1.0);
            float b = clamp(areas.sample(areas.transform(dest.coord())).g, 0.0, 1.0);
            float w = (1.0 - n) * (1.0 - b);
            return float4(c * w, w, 0.0, 1.0);
        }

        // One step back up the fill pyramid: this level's own value where it has weight, the
        // coarser level's filled value elsewhere. Out: value, 1 (weight).
        [[stitchable]] float4 atelierLensBlurFillUp(coreimage::sampler level, coreimage::sampler coarser,
                                                    coreimage::destination dest) {
            float2 v = level.sample(level.transform(dest.coord())).rg;
            float up = coarser.sample(coarser.transform(dest.coord())).r;
            float own = v.y > 0.0001 ? v.x / v.y : 0.0;
            float t = smoothstep(0.0, 0.3, v.y);
            float filled = mix(up, own, t);
            return float4(filled, 1.0, 0.0, 1.0);
        }

        // The blur sizes with the areas: near a detailed Focus edge at least the background's
        // blur beyond it, and in the area there the background's blur; the area as a layer mask
        // where its edge is detailed (Focus strength in green), lowering the blur where smooth;
        // in a Blur area the blur around it, or the most where that is sharp.
        [[stitchable]] float4 atelierLensBlurAreaCoC(coreimage::sampler coc, coreimage::sampler filled,
                                                     coreimage::sampler near, coreimage::sampler areas,
                                                     coreimage::sampler detail, coreimage::destination dest) {
            float c = coc.sample(coc.transform(dest.coord())).r;
            float f = filled.sample(filled.transform(dest.coord())).r;
            float n = clamp(near.sample(near.transform(dest.coord())).r, 0.0, 1.0);
            float2 a = clamp(areas.sample(areas.transform(dest.coord())).rg, 0.0, 1.0);
            float d = clamp(3.0 * detail.sample(detail.transform(dest.coord())).r, 0.0, 1.0);
            float larger = abs(f) > abs(c) ? f : c;
            c = mix(c, larger, n);
            c = mix(c, f, smoothstep(0.0, 0.25, a.x) * n);
            c *= 1.0 - a.x * (1.0 - d);
            float side = f < 0.0 ? -1.0 : 1.0;
            float blurred = mix(side, f, smoothstep(0.05, 0.2, abs(f)));
            c = mix(c, blurred, a.y);
            return float4(c, a.x * d, 0.0, 1.0);
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
            // color and coc are weighted (atelierLensBlurWeigh): a pixel with almost no weight is
            // a hole, sharp at this level. It takes no light of its own and gathers what blurs
            // onto it from around (so the level stays filled up to a sharp edge), and counts as
            // sharp for what spills over it from in front.
            float2 own = coc.sample(coc.transform(p)).rg;
            bool hole = own.y < 0.02;
            float cp = hole ? 0.0 : own.x / own.y;
            if (!hole && abs(cp) * scale.x >= scale.y) { return float4(0.0); }
            // Radii in this level's pixels: a blur past the gather's reach is cut to it.
            cp = sign(cp) * min(abs(cp) * scale.x, R) / R;
            float cpReach = hole ? 1.0 : cp;
            float rp = abs(cp) * R;
            float selfWeight = hole ? 0.0 : 1.0 / max(rp * rp, 1.0);
            float4 ownColor = color.sample(color.transform(p));
            float3 sum = hole ? float3(0.0) : ownColor.rgb / max(ownColor.a, 0.0001) * selfWeight;
            float total = selfWeight;
            float spill = 0.0;
            float2 toEdge = (p - frame.xy) / frame.z;
            for (int i = 0; i < count; i++) {
                float r = R * sqrt((float(i) + 0.5) / float(count));
                float angle = float(i) * 2.39996323;
                float2 o = r * float2(cos(angle), sin(angle));
                float2 q = p + o;
                float2 there = coc.sample(coc.transform(q)).rg;
                if (there.y < 0.02) { continue; }
                float cq = there.x / there.y;
                cq = sign(cq) * min(abs(cq) * scale.x, R) / R;
                // Something farther than this pixel blurs onto it no more than this pixel blurs.
                float reach = (cq > cpReach ? min(abs(cq), abs(cpReach)) : abs(cq)) * R;
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
                float4 seen = color.sample(color.transform(q));
                sum += seen.rgb / max(seen.a, 0.0001) * w;
                total += w;
                if (cq < cp - 0.02 && abs(cq) > abs(cp)) { spill += w; }
            }
            // A hole's spill is measured against a sharp pixel's own weight (1), as at full size.
            float alpha = hole ? spill / (1.0 + spill) : spill / max(total, 0.0001);
            return float4(total > 0.0 ? sum / total : float3(0.0), alpha);
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
            float2 cf = coc.sample(coc.transform(dest.coord())).rg;
            float t = smoothstep(0.25, 1.0, abs(cf.x) * radius);
            // Then the sharp photo through the Focus areas, as a layer mask.
            float3 rgb = mix(mix(s.rgb, max(b.rgb, float3(0.0)), t), s.rgb, clamp(cf.y, 0.0, 1.0));
            return float4(rgb, s.a);
        }

        // The foreground a level found spilling over a pixel that is sharp or nearly so.
        [[stitchable]] float4 atelierLensBlurSpill(coreimage::sampler current, coreimage::sampler level,
                                                   coreimage::sampler coc, float radius, coreimage::destination dest) {
            float4 s = current.sample(current.transform(dest.coord()));
            float4 b = level.sample(level.transform(dest.coord()));
            float2 cf = coc.sample(coc.transform(dest.coord())).rg;
            float c = abs(cf.x) * (1.0 - clamp(cf.y, 0.0, 1.0)) * radius;
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
