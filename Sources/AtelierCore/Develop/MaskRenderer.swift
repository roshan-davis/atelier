import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Gives the renderer a mask component as a grayscale image (white is full effect) in the
/// cropped photo's space, or nil to have the renderer work it out (luminance ranges).
public typealias MaskProvider = (DevelopSettings.MaskComponent) -> CIImage?

/// Pipeline step 6: each mask's own adjustments, blended in through the mask.
extension DevelopRenderer {
    static let maskRed = CIColor(red: 0.95, green: 0.15, blue: 0.1)

    /// Applies every visible mask in order. `masks` supplies the drawn parts; without it they
    /// are drawn straight onto `input`'s frame (no crop).
    static func applyMasks(_ settings: DevelopSettings, to input: CIImage, scale: Double,
                           masks provider: MaskProvider?) -> CIImage {
        var image = input
        for mask in settings.masks where !mask.isHidden && mask.hasAdjustments {
            guard let alpha = maskImage(mask, base: input, provider: provider) else { continue }
            let adjusted = applyLocal(mask, to: image, scale: scale)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = image
            blend.maskImage = alpha
            image = blend.outputImage?.cropped(to: input.extent) ?? image
        }
        return image
    }

    /// Tints the mask red over the photo, like Lightroom's Show Overlay.
    static func overlay(_ mask: DevelopSettings.Mask, on image: CIImage, base: CIImage, provider: MaskProvider?) -> CIImage {
        guard let alpha = maskImage(mask, base: base, provider: provider) else { return image }
        let red = CIImage(color: maskRed).cropped(to: image.extent)
        let tinted = mix(image, red, amount: 0.5)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = tinted
        blend.backgroundImage = image
        blend.maskImage = alpha
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }

    /// The mask's parts combined: Add keeps the brighter, Subtract cuts out, Intersect keeps
    /// only the overlap. `base` is the photo before local adjustments, for luminance ranges.
    public static func maskImage(_ mask: DevelopSettings.Mask, base: CIImage, provider: MaskProvider?) -> CIImage? {
        let extent = base.extent
        var result: CIImage?
        for component in mask.components {
            guard var part = provider?(component) ?? componentImage(component, base: base) else { continue }
            part = part.cropped(to: extent)
            if component.inverted { part = invert(part) }
            switch component.mode {
            case .add:
                result = result.map { maximum($0, part) } ?? part
            case .subtract:
                result = result.map { multiply($0, invert(part)) }
            case .intersect:
                result = result.map { multiply($0, part) }
            }
        }
        guard var combined = result else { return mask.inverted ? CIImage(color: .white).cropped(to: extent) : nil }
        if mask.inverted { combined = invert(combined) }
        return combined.cropped(to: extent)
    }

    /// A part drawn straight onto `base`'s frame, or a luminance range taken from it.
    static func componentImage(_ component: DevelopSettings.MaskComponent, base: CIImage) -> CIImage? {
        if case .luminance(let range) = component.shape { return luminanceMask(range, from: base) }
        if case .color(let range) = component.shape { return colorRangeMask(range, from: base) }
        return sourceMask(component, extent: base.extent, subject: nil, brushCache: nil)
    }

    /// A drawn part on the upright, uncropped photo whose frame is `extent`. Brush strokes are
    /// drawn once and kept in `brushCache` when given; `subject` finds Select Subject's mask
    /// (no box) or Select Object's (inside the box) on the photo's frame; `people` finds Select
    /// People's skin there.
    /// `guide` is the photo on the same frame, which Refine Edge snaps AI selections to; `fine`
    /// gives the Fine Edges model's foreground matte around a selection's outline on that frame
    /// (covering a square around it; nil when not downloaded).
    static func sourceMask(_ component: DevelopSettings.MaskComponent, extent: CGRect,
                           subject: ((DevelopSettings.MaskRect?) -> CIImage?)?,
                           people: ((DevelopSettings.PeopleSelection) -> CIImage?)? = nil,
                           fine: ((CIImage) -> CIImage?)? = nil,
                           guide: CIImage? = nil,
                           brushCache: BrushCache?) -> CIImage? {
        let width = extent.width, height = extent.height
        let longEdge = max(width, height)
        // Mask points are top-left fractions; Core Image's y axis points up.
        func point(_ p: DevelopSettings.MaskPoint) -> CGPoint {
            CGPoint(x: extent.minX + CGFloat(p.x) * width, y: extent.minY + (1 - CGFloat(p.y)) * height)
        }
        switch component.shape {
        case .linear(let gradient):
            let filter = CIFilter.linearGradient()
            filter.point0 = point(gradient.start)
            filter.point1 = point(gradient.end)
            filter.color0 = .white
            filter.color1 = .black
            return filter.outputImage?.cropped(to: extent)
        case .radial(let gradient):
            // A circle of radius 1000 stretched to the ellipse, turned and moved into place.
            let unit: CGFloat = 1000
            let filter = CIFilter.radialGradient()
            filter.center = .zero
            filter.radius0 = Float(unit * CGFloat(max(0.001, 1 - gradient.feather / 100)))
            filter.radius1 = Float(unit)
            filter.color0 = .white
            filter.color1 = .black
            let rx = max(1, CGFloat(gradient.radiusX) * longEdge), ry = max(1, CGFloat(gradient.radiusY) * longEdge)
            let transform = CGAffineTransform(scaleX: rx / unit, y: ry / unit)
                .concatenating(CGAffineTransform(rotationAngle: -CGFloat(gradient.angle) * .pi / 180))
                .concatenating(CGAffineTransform(translationX: point(gradient.center).x, y: point(gradient.center).y))
            return filter.outputImage?.transformed(by: transform).cropped(to: extent)
        case .brush(let strokes):
            let key = BrushCache.Key(strokes: strokes, width: Int(width.rounded()), height: Int(height.rounded()))
            if let cached = brushCache?.image(for: key) {
                return cached.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            }
            guard let cgImage = brushMask(strokes, width: key.width, height: key.height) else { return nil }
            let image = rawMask(cgImage)
            brushCache?.store(image, for: key)
            return image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        case .subject(let selection):
            guard let mask = subject?(selection.box) else { return nil }
            // Select Background is the subject turned inside out: its edge is the same edge, so
            // Grow (which grows the background) shrinks the subject before it is inverted.
            let grow = selection.background ? -selection.grow : selection.grow
            var refined = refinedSelection(mask, grow: grow, refine: selection.refine, feather: selection.feather,
                                           guide: guide, extent: extent)
            // Fine Edges last, so Feather and Refine Edge don't blur away the strands it finds.
            if selection.fineEdges, let matte = fine?(mask) {
                refined = fineEdged(refined, outline: mask, matte: matte, extent: extent)
            }
            return selection.background ? invert(refined).cropped(to: extent) : refined
        case .people(let selection):
            guard let mask = people?(selection) else { return nil }
            let refined = refinedSelection(mask, grow: selection.grow, refine: selection.refine, feather: selection.feather,
                                           guide: guide, extent: extent)
            guard selection.fineEdges else { return refined }
            // The people's own outline, so parts inside them (face skin next to hair) keep their
            // edges and only edges onto the background are redrawn.
            var whole = selection
            whole.parts = [.entirePerson]
            let outline = people?(whole) ?? mask
            guard let matte = fine?(outline) else { return refined }
            return fineEdged(refined, outline: outline, matte: matte, extent: extent)
        case .color(let range):
            // Found on the corrected photo itself, so tone and color sliders don't move it.
            guard let guide else { return nil }
            return colorRangeMask(range, from: guide)?.cropped(to: extent)
        case .luminance:
            return nil
        }
    }

    /// Fine Edges: the selection's edge redrawn from the Fine Edges model's foreground `matte`,
    /// within 3% of the long edge of where Vision put it, where the matte was found (it covers a
    /// square around the selection; outside it nothing changes). Inside the band, pixels inside
    /// `outline` (Vision's outline of the subject or the people) are kept only where the matte
    /// is foreground too (the background between strands of hair drops out), and pixels outside
    /// it are added where the matte is foreground (strands Vision's outline missed). Away from the
    /// edge the selection is unchanged, so someone the model misses keeps their selection.
    /// max(shrunk, min(grown, matte, max(mask, 1 − outline))).
    static func fineEdged(_ mask: CIImage, outline: CIImage, matte: CIImage, extent: CGRect) -> CIImage {
        let radius = max(1, 0.03 * Double(max(extent.width, extent.height)))
        func morphology(_ image: CIImage, _ name: String) -> CIImage {
            image.clampedToExtent().applyingFilter(name, parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        func lower(_ a: CIImage, _ b: CIImage) -> CIImage {
            a.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: b])
        }
        func higher(_ a: CIImage, _ b: CIImage) -> CIImage {
            a.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: b])
        }
        let base = mask.cropped(to: extent)
        // Outside the matte's square the matte is the selection itself, which changes nothing.
        let matte = matte.composited(over: base)
        let shrunk = morphology(base, "CIMorphologyMinimum")
        let grown = morphology(base, "CIMorphologyMaximum")
        let allowed = higher(base, invert(outline.cropped(to: extent)))
        return higher(shrunk, lower(lower(grown, matte.cropped(to: extent)), allowed)).cropped(to: extent)
    }

    /// The edge controls every AI selection shares (Select Subject, Select Object, Select People),
    /// in this order: Grow (-100...100: shrinks or grows the selection by up to 1% of the photo's
    /// long edge), Refine Edge (0...100: a guided filter with the photo as guide, radius up to
    /// 0.8% of the long edge, so the edge moves onto the photo's own edges: hair, a jaw line, an
    /// object's outline) and Feather (0...100: a blur up to 1.2% of the long edge). All three at 0
    /// leave the selection as found. Sizes scale with the photo, so a preview and an export match.
    static func refinedSelection(_ mask: CIImage, grow: Double, refine: Double, feather: Double,
                                 guide: CIImage?, extent: CGRect) -> CIImage {
        let longEdge = Double(max(extent.width, extent.height))
        var result = mask.cropped(to: extent)
        let growRadius = abs(grow) / 100 * 0.01 * longEdge
        if growRadius >= 0.5 {
            result = result.clampedToExtent()
                .applyingFilter(grow > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum",
                                parameters: [kCIInputRadiusKey: growRadius])
                .cropped(to: extent)
        }
        if refine > 0, let guide,
           // Smaller epsilon follows weaker edges in the photo.
           let refined = MaskGuidedFilter.apply(mask: result, guide: guide, radius: max(1, refine / 100 * 0.008 * longEdge),
                                                epsilon: 0.0001 + (1 - refine / 100) * 0.001, extent: extent) {
            result = refined.cropped(to: extent)
        }
        if feather > 0 {
            let sigma = feather / 100 * 0.012 * longEdge
            result = result.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        return result
    }

    /// Paints the strokes as soft round dabs, white on black; erasing strokes paint black.
    /// Flow sets how much each dab adds, so going over an area builds it up as in Lightroom.
    public static func brushMask(_ strokes: [DevelopSettings.MaskStroke], width: Int, height: Int) -> CGImage? {
        let gray = CGColorSpaceCreateDeviceGray()
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip so points read top-down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let longEdge = CGFloat(max(width, height))
        for stroke in strokes where !stroke.points.isEmpty {
            let radius = max(0.5, CGFloat(stroke.size) * longEdge / 2)
            let hard = radius * CGFloat(max(0, 1 - stroke.feather / 100))
            let shade: CGFloat = stroke.erases ? 0 : 1
            let flow = CGFloat(max(0.01, min(1, stroke.flow / 100)))
            guard let gradient = CGGradient(colorSpace: gray, colorComponents: [shade, flow, shade, flow, shade, 0],
                                            locations: [0, hard / radius, 1], count: 3) else { continue }
            let points = stroke.points.map { CGPoint(x: CGFloat($0.x) * CGFloat(width), y: CGFloat($0.y) * CGFloat(height)) }
            let dabs = dabPositions(along: points, spacing: max(1, radius / 5))
            for dab in dabs {
                context.drawRadialGradient(gradient, startCenter: dab, startRadius: 0, endCenter: dab, endRadius: radius,
                                           options: [])
            }
        }
        return context.makeImage()
    }

    /// Dabs every `spacing` along the stroke, carrying the leftover distance from one mouse
    /// sample to the next so short segments still add up, and always ending on the last point.
    static func dabPositions(along points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var dabs = [first]
        var travelled: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let distance = hypot(b.x - a.x, b.y - a.y)
            guard distance > 0 else { continue }
            var along = spacing - travelled
            while along <= distance {
                let t = along / distance
                dabs.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                along += spacing
            }
            travelled = distance - (along - spacing)
        }
        if let last = points.last, last != dabs.last { dabs.append(last) }
        return dabs
    }

    /// A grayscale mask as stored values: without this Core Image reads the gray as
    /// gamma-encoded and darkens every soft edge on the way to linear light.
    static func rawMask(_ cgImage: CGImage) -> CIImage {
        CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
    }

    /// White where the photo's brightness is in the range, from the photo before local
    /// adjustments. Brightness is judged in sRGB-encoded values, as Lightroom shows it.
    static func luminanceMask(_ range: DevelopSettings.LuminanceRange, from base: CIImage) -> CIImage? {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = base
        // Rec. 2020 luma, the working space's primaries.
        let luma = CIVector(x: 0.2627, y: 0.6780, z: 0.0593, w: 0)
        matrix.rVector = luma
        matrix.gVector = luma
        matrix.bVector = luma
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let samples = 256
        var lut = [Float]()
        lut.reserveCapacity(samples * 3)
        for i in 0..<samples {
            // The curve's output is decoded back to linear, so store the weight encoded.
            let value = Float(srgbEncode(range.weight(at: Double(i) / Double(samples - 1))))
            lut.append(contentsOf: [value, value, value])
        }
        let curves = CIFilter.colorCurves()
        curves.inputImage = matrix.outputImage
        curves.curvesData = lut.withUnsafeBufferPointer { Data(buffer: $0) }
        curves.curvesDomain = CIVector(x: 0, y: 1)
        curves.colorSpace = sRGB
        return curves.outputImage?.cropped(to: base.extent)
    }

    /// White where `image`'s colors (working space) are close to the Color Range's picks
    /// (`ColorRange.weight`), worked out per pixel in Oklab on the GPU.
    static func colorRangeMask(_ range: DevelopSettings.ColorRange, from image: CIImage) -> CIImage? {
        guard !range.samples.isEmpty else { return CIImage(color: .black).cropped(to: image.extent) }
        guard let kernel = colorRangeKernel else { return nil }
        let rows = ColorRangeSpace.toLMS
        var arguments: [Any] = [image]
        for row in rows { arguments.append(CIVector(x: CGFloat(row.x), y: CGFloat(row.y), z: CGFloat(row.z))) }
        for i in 0..<DevelopSettings.ColorRange.maxSamples {
            if i < range.samples.count {
                let sample = range.samples[i]
                let zero = range.reach(of: sample).zero
                arguments.append(CIVector(x: CGFloat(sample.l), y: CGFloat(sample.a), z: CGFloat(sample.b), w: CGFloat(zero)))
            } else {
                arguments.append(CIVector(x: 0, y: 0, z: 0, w: -1))
            }
        }
        return kernel.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: arguments)?
            .cropped(to: image.extent)
    }

    /// Whether the Color Range kernel built, for tests.
    static var colorRangeKernelAvailable: Bool { colorRangeKernel != nil }

    private static let colorRangeKernel: CIKernel? = RuntimeKernels.build("""
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        static float atelierColorRangeWeight(float3 lab, float4 pick) {
            if (pick.w <= 0.0) { return 0.0; }
            float3 d = lab - pick.xyz;
            float distance = sqrt(d.y * d.y + d.z * d.z + 0.25 * d.x * d.x);
            float full = pick.w * 0.45;
            float t = clamp((pick.w - distance) / max(pick.w - full, 1e-6), 0.0, 1.0);
            return t * t * (3.0 - 2.0 * t);
        }

        // r0...r2: working space (linear Rec. 2020) to Oklab's LMS. p0...p4: picks (L, a, b, reach).
        [[stitchable]] float4 atelierColorRange(coreimage::sampler image, float3 r0, float3 r1, float3 r2,
                                                float4 p0, float4 p1, float4 p2, float4 p3, float4 p4,
                                                coreimage::destination dest) {
            float3 c = image.sample(image.transform(dest.coord())).rgb;
            float3 lms = float3(dot(r0, c), dot(r1, c), dot(r2, c));
            lms = sign(lms) * pow(abs(lms), float3(1.0 / 3.0));
            float3 lab = float3(0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
                                1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
                                0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z);
            float w = max(max(max(atelierColorRangeWeight(lab, p0), atelierColorRangeWeight(lab, p1)),
                              max(atelierColorRangeWeight(lab, p2), atelierColorRangeWeight(lab, p3))), atelierColorRangeWeight(lab, p4));
            return float4(w, w, w, 1.0);
        }
        """)?["atelierColorRange"]

    static func srgbEncode(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// The mask's sliders on the whole photo; the mask decides where they show.
    static func applyLocal(_ mask: DevelopSettings.Mask, to input: CIImage, scale: Double) -> CIImage {
        var image = input
        let extent = input.extent
        // Detail clean-up first, on the colors as they came in, as the global Defringe and
        // color noise reduction come before tone and color.
        image = MaskSliders.defringe(image, amount: mask.effective(.defringe), scale: scale)
        image = MaskSliders.moire(image, amount: mask.effective(.moire), scale: scale)
        let temperature = mask.effective(.temperature), tint = mask.effective(.tint)
        if temperature != 0 || tint != 0 {
            // Core Image turns `neutral` into `targetNeutral`'s white, so treating a hotter (or
            // more magenta) light as neutral warms (or adds magenta to) the photo, as in Lightroom.
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500 * pow(2, temperature / 100 * 0.8), y: tint)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            image = filter.outputImage ?? image
        }
        let exposure = mask.effective(.exposure)
        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(exposure)
            image = filter.outputImage ?? image
        }
        // The rest are the global steps with the mask's values.
        var local = DevelopSettings()
        local.contrast = mask.effective(.contrast)
        local.highlights = mask.effective(.highlights)
        local.shadows = mask.effective(.shadows)
        local.whites = mask.effective(.whites)
        local.blacks = mask.effective(.blacks)
        local.texture = mask.effective(.texture)
        local.clarity = mask.effective(.clarity)
        local.dehaze = mask.effective(.dehaze)
        local.saturation = mask.effective(.saturation)
        local.luminanceNoise = mask.effective(.noise)
        let sharpness = mask.effective(.sharpness)
        if sharpness > 0 {
            local.sharpening = sharpness * 1.2
            local.sharpenRadius = 1
        }
        image = applyAdjustments(local, to: image, scale: scale)
        image = MaskSliders.hue(image, degrees: mask.effective(.hue))
        if sharpness < 0 {
            // Negative sharpness softens, as in Lightroom.
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, 3 * scale)).cropped(to: extent)
            image = mix(image, blurred, amount: min(1, -sharpness / 100))
        }
        return image.cropped(to: extent)
    }

    static func invert(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorInvert()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    static func maximum(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.maximumCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
    }

    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.multiplyCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
    }
}

/// Drawn brush masks, kept per open photo so a slider change doesn't redraw every stroke.
final class BrushCache: @unchecked Sendable {
    struct Key: Hashable {
        let strokes: [DevelopSettings.MaskStroke]
        let width: Int
        let height: Int
    }

    private var images: [Key: CIImage] = [:]
    private let lock = NSLock()

    func image(for key: Key) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    func store(_ image: CIImage, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        // Painting makes a new key per stroke; keep the cache small.
        if images.count >= 12 { images.removeAll() }
        images[key] = image
    }
}
