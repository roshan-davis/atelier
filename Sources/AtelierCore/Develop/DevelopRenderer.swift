import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders develop settings on the GPU with Core Image, following the PRD pipeline order:
/// RAW decode with white balance and exposure, geometry, then highlights and shadows and the
/// tone curve in a perceptual space, presence (dehaze, clarity, texture), color, detail,
/// masks and effects.
public final class DevelopRenderer: @unchecked Sendable {
    public static let shared = DevelopRenderer()

    public let context: CIContext
    /// Linear Rec. 2020 working space, as in the PRD.
    public static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    public static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Camera matches by file and modification date; see `CameraMatch`.
    let cameraMatches = NSCache<NSString, CameraMatchBox>()
    /// Lateral chromatic aberration by file; see `LateralCA`.
    let lateralCAs = NSCache<NSString, LateralCABox>()

    public init() {
        context = CIContext(options: [
            .workingColorSpace: Self.workingSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
        ])
    }

    /// Opens a photo for editing. Keep the session while the photo is on screen; it reuses
    /// the decoded source between slider changes. `interactive` keeps the decoded,
    /// lens-corrected photo between renders, for sessions that render again and again (Develop);
    /// one-off renders (previews, export) leave it off so they don't fill Core Image's cache.
    public func session(for url: URL, maxPixelSize: Int?, interactive: Bool = false) -> DevelopSession? {
        DevelopSession(url: url, maxPixelSize: maxPixelSize, renderer: self, interactive: interactive)
    }

    /// Rendered now, on the calling thread. Without `deferred: false` Core Image may hand back
    /// a CGImage that renders only when first drawn, which for the photo view means on the main
    /// thread. (In CI a full-size 24 MP render returned in 7 ms, which only a deferred render
    /// explains.)
    public func cgImage(_ image: CIImage, colorSpace: CGColorSpace = DevelopRenderer.displaySpace) -> CGImage? {
        context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: colorSpace, deferred: false)
    }

    // MARK: Geometry

    /// Turns, flips, straightens and crops (the order is described on `DevelopSettings.Crop`).
    /// With `cropping` false the straightened photo is returned whole, for the crop tool,
    /// and its extent is the rotated photo's bounding box around the turned photo's frame.
    public static func applyGeometry(_ crop: DevelopSettings.Crop, to input: CIImage, cropping: Bool = true) -> CIImage {
        var image = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let turns = ((crop.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            // Clockwise in a y-up space is a negative angle.
            image = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let size = image.extent.size
        if crop.flipHorizontal {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
        }
        if crop.flipVertical {
            image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
        }
        if crop.angle != 0 {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: -CGFloat(crop.angle) * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            // Clamp first so the edges stay sharp when sampled.
            image = image.clampedToExtent().transformed(by: rotation)
                .cropped(to: CGRect(origin: .zero, size: size).applying(rotation))
            // Clamping smears the edge pixels into streaks past the photo's tilted edges; the
            // crop stays on the photo, but the crop tool shows those corners, so cut them away.
            if !cropping { image = straightenedOutline(crop, size: size, of: image) }
        }
        guard cropping else { return image }
        // The crop is measured from the top left; Core Image's y axis points up.
        let rect = CGRect(x: crop.x * size.width, y: (1 - crop.y - crop.height) * size.height,
                          width: crop.width * size.width, height: crop.height * size.height).integral
        image = image.cropped(to: rect)
        return image.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// `image` with everything outside the straightened photo made transparent, so the crop
    /// tool shows empty corners around the tilted photo, as Lightroom does. `size` is the
    /// turned photo's size; the edge is antialiased.
    public static func straightenedOutline(_ crop: DevelopSettings.Crop, size: CGSize, of image: CIImage) -> CIImage {
        guard crop.angle != 0 else { return image }
        let rotation = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .rotated(by: -CGFloat(crop.angle) * .pi / 180)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        let outline = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size)).transformed(by: rotation)
        return image.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: outline])
            .cropped(to: image.extent)
    }

    // MARK: Adjustments after decode

    /// Steps 2 to 7 of the pipeline; white balance and exposure happen at decode.
    /// `scale` is the rendered size relative to the full-size photo, so pixel radii such as
    /// sharpening look the same on the live proxy and in an export. `masks` supplies the masks'
    /// drawn parts lined up with the crop; `overlay` names a mask to tint red on top. `preview`
    /// replaces the result with a slider's Option-drag view.
    public static func applyAdjustments(_ settings: DevelopSettings, to input: CIImage, scale: Double = 1,
                                        masks: MaskProvider? = nil, overlay: UUID? = nil,
                                        preview: SliderPreview? = nil) -> CIImage {
        var settings = settings
        switch preview {
        case .fullSaturation(let region):
            settings[region.saturation] = 100
        case .blendingSaturation:
            for region in DevelopSettings.GradeRegion.allCases where settings[region.saturation] > 0 {
                settings[region.saturation] = 100
            }
        case .gradeSolo(let only):
            for region in DevelopSettings.GradeRegion.allCases where region != only {
                settings[region.saturation] = 0
                settings[region.luminance] = 0
            }
        default:
            break
        }
        var image = input
        let extent = input.extent

        // Highlights and Shadows: local, judged by an edge-aware base (see LocalContrast).
        image = LocalContrast.toneRegions(image, highlights: settings.highlights / 100, shadows: settings.shadows / 100,
                                          scale: scale)

        // Tone curve, applied in sRGB-encoded values so contrast behaves perceptually. Basic tone,
        // the region curve and the RGB curve keep each color's hue, as Lightroom does; the
        // Red, Green and Blue curves then work on their own channel, as color curves should.
        // Refine Saturation below 100 runs the RGB point curve on its own, so it can hold back
        // the saturation the point curve adds without changing Basic tone or the regions.
        let refine = settings[.curveRefineSaturation] / 100
        let master = settings.points(for: .rgb)
        let refinesPointCurve = refine < 1 && master != DevelopSettings.CurvePoint.identity
        if let lut = masterCurveLUT(settings, includingPointCurve: !refinesPointCurve) {
            image = ToneCurve.apply(lut, to: image)
        }
        if refinesPointCurve {
            image = ToneCurve.apply(pointCurveLUT(master), to: image, refine: refine)
        }
        if let lut = channelCurvesLUT(settings) {
            image = ToneCurve.applyChannels(lut, to: image)
        }

        if settings.dehaze != 0 {
            image = dehaze(image, amount: settings.dehaze / 100)
        }
        // Clarity works on wide areas, weighted to the midtones; Texture on medium-sized detail.
        if settings.clarity != 0 {
            image = LocalContrast.apply(image, amount: settings.clarity / 100, kind: LocalContrast.clarity, scale: scale)
        }
        if settings.texture != 0 {
            image = LocalContrast.apply(image, amount: settings.texture / 100, kind: LocalContrast.texture, scale: scale)
        }

        // In Black & White the B&W Mix decides the grays, so vibrance and saturation do nothing.
        if settings.vibrance != 0, !settings.monochrome {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(settings.vibrance / 100)
            image = filter.outputImage ?? image
        }
        if settings.saturation != 0, !settings.monochrome {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(1 + settings.saturation / 100)
            filter.brightness = 0
            filter.contrast = 1
            image = filter.outputImage ?? image
        }

        // HSL, Point Color (or the B&W Mix) and color grading share one color cube (see ColorLUT).
        switch preview {
        case .gradeRegions:
            // Balance's view stops here: what matters is which tones fall in which range.
            return colorCube(ColorLUT.regionMapCube(for: settings), on: image)
        case .pointColorRange(let swatch):
            // So does Point Color's Visualize Range: the colors the swatch selects, the rest gray.
            return colorCube(ColorLUT.pointRangeCube(for: settings, swatch: swatch), on: image)
        default:
            break
        }
        if let cube = ColorLUT.cube(for: settings) {
            image = colorCube(cube, on: image)
        }

        // Detail
        if settings.luminanceNoise > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(settings.luminanceNoise / 100 * 0.06)
            filter.sharpness = 0.4
            image = filter.outputImage?.cropped(to: extent) ?? image
        }
        if settings.colorNoise > 0 {
            // Keep the original luminance and take color from a blurred copy.
            let blurred = image.clampedToExtent()
                .applyingGaussianBlur(sigma: max(0.5, 4 * scale * settings.colorNoise / 50))
                .cropped(to: extent)
            let blend = CIFilter.luminosityBlendMode()
            blend.inputImage = image
            blend.backgroundImage = blurred
            if let output = blend.outputImage?.cropped(to: extent) {
                image = mix(image, output, amount: min(1, settings.colorNoise / 50))
            }
        }
        switch preview {
        case .sharpenEdges:
            // Shown even at Amount 0, so Radius and Detail can be judged before sharpening.
            return SliderPreview.halos(base: image, sharpened: sharpen(image, settings, amount: max(settings.sharpening, 50),
                                                                       scale: scale, extent: extent))
        case .sharpenMask:
            return SliderPreview.edgeMask(image, masking: settings[.sharpenMasking], scale: scale)
        default:
            break
        }
        if settings.sharpening > 0 {
            let sharpened = sharpen(image, settings, amount: settings.sharpening, scale: scale, extent: extent)
            if settings[.sharpenMasking] > 0 {
                let filter = CIFilter.blendWithMask()
                filter.inputImage = sharpened
                filter.backgroundImage = image
                filter.maskImage = SliderPreview.edgeMask(image, masking: settings[.sharpenMasking], scale: scale)
                image = filter.outputImage?.cropped(to: extent) ?? sharpened
            } else {
                image = sharpened
            }
        }

        // Local adjustments, before vignetting and grain.
        let beforeMasks = image
        if !settings.masks.isEmpty {
            image = applyMasks(settings, to: image, scale: scale, masks: masks)
        }

        // Effects: Glow, then Post-Crop Vignetting and Grain, as in Lightroom.
        if settings[.glowAmount] > 0 {
            image = Glow.apply(image, settings: settings, extent: extent)
        }
        if settings.vignette != 0 {
            image = PostCropVignette.apply(image, settings: settings, extent: extent)
        }
        if settings.grain > 0 {
            image = FilmGrain.apply(image, amount: settings.grain / 100, size: settings.grainSize / 100,
                                    roughness: settings.grainRoughness / 100, type: settings.grainType,
                                    scale: scale, extent: extent)
        }
        if let overlay, let mask = settings.masks.first(where: { $0.id == overlay }) {
            image = self.overlay(mask, on: image, base: beforeMasks, provider: masks)
        }
        switch preview {
        case .sharpenAmount: image = SliderPreview.grayscale(image)
        case .highlightClipping: image = SliderPreview.clipping(image, highlights: true)
        case .shadowClipping: image = SliderPreview.clipping(image, highlights: false)
        default: break
        }
        return image
    }

    /// The HSL and grading cube on `image`; see `ColorLUT`.
    static func colorCube(_ data: Data, on image: CIImage) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(ColorLUT.dimension)
        filter.cubeData = data
        filter.colorSpace = ColorLUT.space
        return filter.outputImage ?? image
    }

    /// Removes (positive) or adds (negative) haze; see `Dehaze`.
    static func dehaze(_ image: CIImage, amount: Double) -> CIImage {
        Dehaze.apply(image, amount: amount)
    }

    /// Sharpening on luminance at Amount (0...150) and Radius. Detail below its default of 25
    /// sharpens less at the radius, holding back halos; above it, a finer second pass brings
    /// out texture. At 25 this is a single pass.
    static func sharpen(_ image: CIImage, _ settings: DevelopSettings, amount: Double, scale: Double,
                        extent: CGRect) -> CIImage {
        let detail = settings[.sharpenDetail]
        let strength = amount / 150 * 1.2
        let radius = max(0.3, settings.sharpenRadius * scale * 1.5)
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = Float(strength * (detail < 25 ? 0.5 + detail / 50 : 1))
        filter.radius = Float(radius)
        var output = filter.outputImage?.cropped(to: extent) ?? image
        if detail > 25 {
            let fine = CIFilter.sharpenLuminance()
            fine.inputImage = output
            fine.sharpness = Float(strength * (detail - 25) / 75 * 0.7)
            fine.radius = Float(max(0.3, radius * 0.4))
            output = fine.outputImage?.cropped(to: extent) ?? output
        }
        return output
    }

    static func mix(_ image: CIImage, _ other: CIImage, amount: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = image
        filter.targetImage = other
        filter.time = Float(amount)
        return filter.outputImage ?? image
    }

    /// Control points of the tone curve in sRGB-encoded values, or nil when it is the identity.
    public static func toneCurvePoints(_ settings: DevelopSettings) -> [CGPoint]? {
        let c = settings.contrast / 100
        let w = settings.whites / 100
        let b = settings.blacks / 100
        guard c != 0 || w != 0 || b != 0 else { return nil }
        return [
            CGPoint(x: max(0, -b) * 0.1, y: max(0, b) * 0.1),
            CGPoint(x: 0.25, y: 0.25 - c * 0.08),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: min(1, 0.75 + c * 0.08)),
            CGPoint(x: 1 - max(0, w) * 0.1, y: 1 - max(0, -w) * 0.1),
        ]
    }

    /// The Tone Curve panel's region sliders, from dark to light.
    public static let curveRegions: [DevelopSettings.Parameter] = [.curveShadows, .curveDarks, .curveLights, .curveHighlights]

    /// The three split points between the regions (Lightroom's triangles under the curve), 0...1,
    /// kept in order at least 5% apart.
    public static func curveSplits(_ settings: DevelopSettings) -> (Double, Double, Double) {
        let middle = min(0.85, max(0.15, settings[.curveMidtoneSplit] / 100))
        let low = min(middle - 0.05, max(0.05, settings[.curveShadowSplit] / 100))
        let high = max(middle + 0.05, min(0.95, settings[.curveHighlightSplit] / 100))
        return (low, middle, high)
    }

    /// Control points of the region curve (Lightroom's parametric curve): each slider moves the
    /// middle of its region by up to 12% of the range, and the curve passes through them with
    /// the monotone spline. Black and white stay where they are, and the points are kept rising,
    /// so the curve never fogs black, dims white or turns tones over. Nil when every slider is 0.
    public static func regionCurvePoints(_ settings: DevelopSettings) -> [CGPoint]? {
        let amounts = curveRegions.map { settings[$0] / 100 }
        guard amounts.contains(where: { $0 != 0 }) else { return nil }
        let (low, middle, high) = curveSplits(settings)
        let centers = [low / 2, (low + middle) / 2, (middle + high) / 2, (high + 1) / 2]
        var ys = [0.0] + zip(centers, amounts).map { min(1, max(0, $0 + $1 * 0.12)) } + [1.0]
        let gap = 0.001
        for i in 1..<(ys.count - 1) { ys[i] = max(ys[i], ys[i - 1] + gap) }
        for i in stride(from: ys.count - 2, through: 1, by: -1) { ys[i] = min(ys[i], ys[i + 1] - gap) }
        let xs = [0.0] + centers + [1.0]
        return zip(xs, ys).map { CGPoint(x: $0, y: $1) }
    }

    public static func hasToneCurve(_ settings: DevelopSettings) -> Bool {
        toneCurvePoints(settings) != nil || regionCurvePoints(settings) != nil || settings.hasPointCurve
    }

    /// A point curve evaluated with the same monotone spline as the tone curve.
    public static func pointCurveValue(_ points: [DevelopSettings.CurvePoint], at x: Double) -> Double {
        guard points.count >= 2 else { return x }
        return evaluateCurve(points.map { CGPoint(x: $0.x, y: $0.y) }, at: x)
    }

    /// The region curve alone at `x` (sRGB-encoded 0...1).
    public static func regionCurveValue(_ settings: DevelopSettings, at x: Double) -> Double {
        regionCurvePoints(settings).map { evaluateCurve($0, at: x) } ?? x
    }

    /// The full tone curve at `x` (sRGB-encoded 0...1): Basic tone, then the Tone Curve panel's
    /// region curve on its result, as Lightroom applies its parametric curve after Basic.
    public static func toneCurveValue(_ settings: DevelopSettings, at x: Double) -> Double {
        let basic = toneCurvePoints(settings).map { evaluateCurve($0, at: x) } ?? x
        let regions = regionCurvePoints(settings)
        return min(1, max(0, regions.map { evaluateCurve($0, at: basic) } ?? basic))
    }

    /// Basic and region tone (never decreasing, so tones keep their order), then the RGB point
    /// curve unless `includingPointCurve` is false, sampled from 0 to 1; nil when it is a
    /// straight line.
    static func masterCurveLUT(_ settings: DevelopSettings, samples: Int = 1024,
                               includingPointCurve: Bool = true) -> [Float]? {
        let master = includingPointCurve ? settings.points(for: .rgb) : DevelopSettings.CurvePoint.identity
        guard toneCurvePoints(settings) != nil || regionCurvePoints(settings) != nil
                || master != DevelopSettings.CurvePoint.identity else { return nil }
        var lut = [Float]()
        lut.reserveCapacity(samples)
        var previous = 0.0
        for i in 0..<samples {
            let base = max(previous, toneCurveValue(settings, at: Double(i) / Double(samples - 1)))
            previous = base
            lut.append(Float(pointCurveValue(master, at: base)))
        }
        return lut
    }

    /// A point curve alone, sampled from 0 to 1.
    static func pointCurveLUT(_ points: [DevelopSettings.CurvePoint], samples: Int = 1024) -> [Float] {
        (0..<samples).map { Float(pointCurveValue(points, at: Double($0) / Double(samples - 1))) }
    }

    /// The Red, Green and Blue point curves sampled as RGB triples for CIColorCurves; nil when
    /// all three are straight lines.
    static func channelCurvesLUT(_ settings: DevelopSettings, samples: Int = 1024) -> [Float]? {
        let channels = [settings.points(for: .red), settings.points(for: .green), settings.points(for: .blue)]
        guard channels.contains(where: { $0 != DevelopSettings.CurvePoint.identity }) else { return nil }
        var lut = [Float]()
        lut.reserveCapacity(samples * 3)
        for i in 0..<samples {
            let x = Double(i) / Double(samples - 1)
            for points in channels {
                lut.append(Float(pointCurveValue(points, at: x)))
            }
        }
        return lut
    }

    /// Monotone cubic (Fritsch-Carlson) through the points, flat outside them, so the curve
    /// never overshoots and never inverts tones.
    public static func evaluateCurve(_ points: [CGPoint], at x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return x }
        if x <= first.x { return min(1, max(0, first.y)) }
        if x >= last.x { return min(1, max(0, last.y)) }
        let n = points.count
        var deltas = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            deltas[i] = (points[i + 1].y - points[i].y) / (points[i + 1].x - points[i].x)
        }
        var slopes = [Double](repeating: 0, count: n)
        slopes[0] = deltas[0]
        slopes[n - 1] = deltas[n - 2]
        for i in 1..<(n - 1) {
            slopes[i] = deltas[i - 1] * deltas[i] <= 0 ? 0 : (deltas[i - 1] + deltas[i]) / 2
        }
        for i in 0..<(n - 1) {
            if deltas[i] == 0 {
                slopes[i] = 0
                slopes[i + 1] = 0
                continue
            }
            let a = slopes[i] / deltas[i], b = slopes[i + 1] / deltas[i]
            let sum = a * a + b * b
            if sum > 9 {
                let t = 3 / sum.squareRoot()
                slopes[i] = t * a * deltas[i]
                slopes[i + 1] = t * b * deltas[i]
            }
        }
        var k = 0
        while x > points[k + 1].x { k += 1 }
        let x0 = points[k].x, x1 = points[k + 1].x, span = x1 - x0
        let t = (x - x0) / span, t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * points[k].y + (t3 - 2 * t2 + t) * span * slopes[k]
            + (-2 * t3 + 3 * t2) * points[k + 1].y + (t3 - t2) * span * slopes[k + 1]
        return min(1, max(0, y))
    }
}

/// One open photo. RAW files keep their CIRAWFilter so white balance and exposure re-render
/// from sensor data; other formats keep a decoded, downscaled CIImage.
public final class DevelopSession: @unchecked Sendable {
    public let url: URL
    public let isRAW: Bool
    private let renderer: DevelopRenderer
    private let rawFilter: CIRAWFilter?
    private let baseImage: CIImage?
    /// As-shot white balance, shown on the temperature slider until the user changes it.
    public let asShotTemperature: Double
    public let asShotTint: Double
    /// The base look matched to the camera's embedded preview, applied right after decode.
    public let cameraMatch: CameraMatch
    /// Rendered size relative to the full-size photo.
    public let renderScale: Double
    /// The decoded photo's size at `renderScale`, upright, before any crop or turn.
    public let sourceSize: CGSize
    /// The lens, from the file's metadata, for the Lens Corrections panel.
    public let lensName: String?
    /// 35 mm equivalent focal length (0 when unknown), for the Transform's perspective.
    public let focalLength35: Double
    /// Whether Apple's RAW engine has lens corrections for this file.
    public let lensCorrectionSupported: Bool
    private let lock = NSLock()
    private let brushCache = BrushCache()
    /// Select Subject's and Select Object's masks on the corrected photo, by box, found once per
    /// lens geometry; a nil mask when Vision found nothing.
    private var subjectMasks: [DevelopSettings.MaskRect?: CIImage?] = [:]
    private var subjectKey: DevelopSettings?
    /// Pipeline step 1's results for the settings they were made from (see `CorrectedKey`), so a
    /// slider on any later panel doesn't decode the RAW and redo the lens corrections again.
    /// Two are kept, most recent last, so the Before view and the edit don't push each other out.
    private var correctedCache: [(key: CorrectedKey, image: CIImage)] = []
    /// Whether `correctedCache` is used; see `DevelopRenderer.session(for:maxPixelSize:interactive:)`.
    private let interactive: Bool

    init?(url: URL, maxPixelSize: Int?, renderer: DevelopRenderer, interactive: Bool = false) {
        self.url = url
        self.renderer = renderer
        self.interactive = interactive
        var lensName: String?
        var focal = 0.0
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            lensName = exif[kCGImagePropertyExifLensModel] as? String
            focal = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue ?? 0
        }
        self.lensName = lensName?.trimmingCharacters(in: .whitespaces)
        focalLength35 = focal
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .rawImage) == true, let raw = CIRAWFilter(imageURL: url) {
            isRAW = true
            rawFilter = raw
            baseImage = nil
            if let maxPixelSize {
                let longEdge = max(raw.nativeSize.width, raw.nativeSize.height)
                if longEdge > 0 { raw.scaleFactor = Float(min(1, Double(maxPixelSize) / Double(longEdge))) }
            }
            renderScale = Double(raw.scaleFactor)
            sourceSize = raw.outputImage?.extent.size ?? raw.nativeSize
            asShotTemperature = Double(raw.neutralTemperature)
            asShotTint = Double(raw.neutralTint)
            cameraMatch = renderer.cameraMatch(for: url)
            lensCorrectionSupported = raw.isLensCorrectionSupported
        } else {
            guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            var scale = 1.0
            if let maxPixelSize {
                let longEdge = max(image.extent.width, image.extent.height)
                if longEdge > CGFloat(maxPixelSize) {
                    scale = Double(CGFloat(maxPixelSize) / longEdge)
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
            }
            renderScale = scale
            sourceSize = image.extent.size
            isRAW = false
            rawFilter = nil
            baseImage = image
            asShotTemperature = 6500
            asShotTint = 0
            cameraMatch = .identity
            lensCorrectionSupported = false
        }
    }

    /// The developed image in the working space. With `cropping` false the crop is left out
    /// (the photo is still turned and straightened), for the crop tool. `overlay` names a mask
    /// to tint red, for the Masks panel's Show Overlay; `preview` is a slider's Option-drag view.
    public func image(with settings: DevelopSettings, cropping: Bool = true, overlay: UUID? = nil,
                      preview: SliderPreview? = nil) -> CIImage? {
        let settings = settings.applyingPanelSwitches()
        lock.lock()
        defer { lock.unlock() }
        if let view = preview?.defringeView {
            // Defringe's Option-drag views show step 1 alone, cropped like the photo.
            guard var image = corrected(settings, defringeView: view) else { return nil }
            if let crop = settings.crop { image = DevelopRenderer.applyGeometry(crop, to: image, cropping: cropping) }
            return image
        }
        guard var image = corrected(settings) else { return nil }
        let sourceExtent = image.extent
        let source = image
        let crop = settings.crop
        if let crop {
            image = DevelopRenderer.applyGeometry(crop, to: image, cropping: cropping)
        }
        let key = settings.lensGeometryKey
        let provider: MaskProvider = { [self] component in
            if case .luminance = component.shape { return nil }
            guard let mask = DevelopRenderer.sourceMask(component, extent: sourceExtent,
                                                        subject: { self.subject(of: source, key: key, box: $0) },
                                                        brushCache: brushCache) else { return nil }
            guard let crop else { return mask }
            return DevelopRenderer.applyGeometry(crop, to: mask, cropping: cropping)
        }
        let adjusted = DevelopRenderer.applyAdjustments(settings, to: image, scale: renderScale, masks: provider,
                                                        overlay: overlay, preview: preview)
        guard !cropping, let crop else { return adjusted }
        // Vignetting and grain would paint the crop tool's empty corners; cut them again.
        return DevelopRenderer.straightenedOutline(crop, size: crop.orientedSize(sourceExtent.size), of: adjusted)
    }

    /// Pipeline step 1: decode with white balance and exposure, the profile, then the lens
    /// corrections (chromatic aberration, Defringe, vignetting, distortion) and the Transform.
    /// The result starts at the origin. Call with the lock held.
    private func corrected(_ settings: DevelopSettings, defringeView: Defringe.View = .photo) -> CIImage? {
        let settings = settings.applyingPanelSwitches()
        guard interactive else { return decodeAndCorrect(settings, defringeView: defringeView) }
        let key = CorrectedKey(settings, view: defringeView)
        if let index = correctedCache.firstIndex(where: { $0.key == key }) {
            let cached = correctedCache.remove(at: index)
            correctedCache.append(cached)
            return cached.image
        }
        guard let image = decodeAndCorrect(settings, defringeView: defringeView) else { return nil }
        // Core Image keeps the rendered step 1 in its cache even though the context's
        // intermediates are off, so the next render starts from it instead of the RAW.
        let kept = image.insertingIntermediate(cache: true)
        correctedCache.append((key, kept))
        if correctedCache.count > 2 { correctedCache.removeFirst() }
        return kept
    }

    /// Everything step 1 (`decodeAndCorrect`) reads, after the panel switches. Add a setting
    /// here whenever step 1 starts to use it, or edits to it won't show until another step-1
    /// setting changes.
    struct CorrectedKey: Equatable {
        let geometry: DevelopSettings
        let temperature: Double?
        let tint: Double
        let exposure: Double
        let profile: DevelopSettings.Profile
        let removeChromaticAberration: Bool
        let defringe: [Double]
        let view: Defringe.View

        init(_ settings: DevelopSettings, view: Defringe.View) {
            // Lens profile corrections, lens vignetting and distortion, Upright and Transform.
            geometry = settings.lensGeometryKey
            temperature = settings.temperature
            tint = settings.tint
            exposure = settings.exposure
            profile = settings.profile
            removeChromaticAberration = settings.removeChromaticAberration
            defringe = DevelopSettings.Parameter.allCases.filter(\.isDefringe).map { settings[$0] }
            self.view = view
        }
    }

    private func decodeAndCorrect(_ settings: DevelopSettings, defringeView: Defringe.View) -> CIImage? {
        var image: CIImage
        if let raw = rawFilter {
            raw.neutralTemperature = Float(settings.temperature ?? asShotTemperature)
            raw.neutralTint = Float(asShotTint + settings.tint)
            raw.exposure = Float(settings.exposure)
            if lensCorrectionSupported, raw.isLensCorrectionEnabled != settings.lensProfileCorrections {
                raw.isLensCorrectionEnabled = settings.lensProfileCorrections
            }
            guard let output = raw.outputImage else { return nil }
            image = settings.profile == .appleNeutral ? output : cameraMatch.apply(to: output)
        } else {
            guard let base = baseImage else { return nil }
            image = base
            let temperature = settings.temperature ?? asShotTemperature
            if temperature != asShotTemperature || settings.tint != 0 {
                // As on a RAW: the photo is treated as lit by `temperature`, so a higher Temp
                // warms it and a higher Tint adds magenta. Core Image turns `neutral` into
                // `targetNeutral`'s white.
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = image
                filter.neutral = CIVector(x: temperature, y: settings.tint)
                filter.targetNeutral = CIVector(x: asShotTemperature, y: 0)
                image = filter.outputImage ?? image
            }
            if settings.exposure != 0 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = image
                filter.ev = Float(settings.exposure)
                image = filter.outputImage ?? image
                if settings.exposure > 0 { image = ExposureRolloff.apply(image) }
            }
        }
        // Masks are drawn on the upright photo's frame, so start it at the origin.
        if image.extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let extent = image.extent
        // Remove Chromatic Aberration, measured once per file from a render big enough to see it.
        if settings.removeChromaticAberration {
            let profile = settings.lensProfileCorrections
            let lateral: LateralCA? = max(extent.width, extent.height) >= LateralCA.minimumSize
                ? renderer.lateralCA(for: url, profileCorrections: profile, image: image)
                : renderer.cachedLateralCA(for: url, profileCorrections: profile)
            if let lateral { image = lateral.apply(to: image) }
        }
        image = Defringe.apply(image, settings: settings, scale: renderScale, view: defringeView)
        // Lens vignetting, around the uncropped photo's center, before the warp moves it.
        if settings[.lensVignette] != 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = image
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            let diagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2
            filter.radius = Float(diagonal * (0.35 + settings[.lensVignetteMidpoint] / 100 * 0.6))
            filter.falloff = 0.6
            filter.intensity = Float(-settings[.lensVignette] / 100)
            image = filter.outputImage?.cropped(to: extent) ?? image
        }
        if settings.hasLensGeometry {
            image = LensGeometry(settings: settings, size: extent.size, focalLength35: focalLength35).apply(to: image)
        }
        return image
    }

    /// Straight edges in the photo after its lens corrections and before the Transform, for
    /// Upright.
    public func lines(for settings: DevelopSettings) -> [LineSegment] {
        var plain = settings
        plain.upright = nil
        plain.constrainCrop = false
        for parameter in DevelopSettings.Panel.transform.parameters { plain[parameter] = parameter.defaultValue }
        lock.lock()
        let image = corrected(plain)
        lock.unlock()
        guard let image else { return [] }
        let extent = image.extent
        let factor = min(1, 800 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let cgImage = renderer.context.createCGImage(small, from: small.extent.integral, format: .RGBA8,
                                                           colorSpace: DevelopRenderer.sRGB) else { return [] }
        let width = cgImage.width, height = cgImage.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        return LineDetector.detect(gray.map { Float($0) / 255 }, width: width, height: height)
    }

    /// Finds the subject with Vision, on the whole photo or just inside `box`, once per lens
    /// geometry. Inside a box a small subject fills Vision's view, so it is found.
    private func subject(of source: CIImage, key: DevelopSettings, box: DevelopSettings.MaskRect?) -> CIImage? {
        if subjectKey != key {
            subjectMasks = [:]
            subjectKey = key
        }
        if let cached = subjectMasks[box] { return cached }
        let extent = source.extent
        var region = extent
        if let box {
            region = CGRect(x: extent.minX + box.x * extent.width, y: extent.minY + (1 - box.y - box.height) * extent.height,
                            width: box.width * extent.width, height: box.height * extent.height)
                .integral.intersection(extent)
        }
        var found: CIImage?
        if region.width >= 8, region.height >= 8 {
            // Vision works on about 1024 pixels; small boxes are enlarged up to 4×.
            let factor = min(4, 1024 / max(region.width, region.height))
            let piece = source.cropped(to: region)
                .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
                .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            if let cgImage = renderer.context.createCGImage(piece, from: piece.extent.integral, format: .RGBA8,
                                                            colorSpace: DevelopRenderer.sRGB),
               let mask = try? AIImaging.subjectMask(for: cgImage) {
                let image = DevelopRenderer.rawMask(mask)
                var placed = image
                    .transformed(by: CGAffineTransform(scaleX: region.width / image.extent.width,
                                                       y: region.height / image.extent.height))
                    .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
                if box != nil {
                    placed = placed.composited(over: CIImage(color: .black).cropped(to: extent))
                }
                found = placed.cropped(to: extent)
            }
        }
        subjectMasks.updateValue(found, forKey: box)
        return found
    }

    /// Whether Vision finds anything for a Select Subject or Select Object part, so the Masks
    /// panel can say so instead of leaving an empty mask.
    public func findsSubject(_ selection: DevelopSettings.Selection, settings: DevelopSettings) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let source = corrected(settings) else { return false }
        return subject(of: source, key: settings.lensGeometryKey, box: selection.box) != nil
    }

    /// The working-space colors in a square `radius` pixels around `point` (0...1 from the top
    /// left of the cropped photo), after chromatic aberration and before Defringe, for the
    /// Fringe Color Selector.
    public func fringeColors(at point: CGPoint, settings: DevelopSettings, radius: Int = 2) -> [SIMD3<Double>] {
        var plain = settings
        for color in DevelopSettings.FringeColor.allCases { plain[color.amount] = 0 }
        lock.lock()
        var image = corrected(plain)
        if let whole = image, let crop = settings.crop {
            image = DevelopRenderer.applyGeometry(crop, to: whole)
        }
        lock.unlock()
        guard let image else { return [] }
        let extent = image.extent
        let x = extent.minX + point.x * extent.width, y = extent.minY + (1 - point.y) * extent.height
        let side = CGFloat(radius * 2 + 1)
        let region = CGRect(x: (x - side / 2).rounded(.down), y: (y - side / 2).rounded(.down), width: side, height: side)
            .intersection(extent.integral)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return [] }
        let width = Int(region.width), height = Int(region.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            renderer.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: region,
                                    format: .RGBAf, colorSpace: DevelopRenderer.workingSpace)
        }
        return (0..<(width * height)).map {
            SIMD3(Double(pixels[$0 * 4]), Double(pixels[$0 * 4 + 1]), Double(pixels[$0 * 4 + 2]))
        }
    }

    /// The finished photo's average sRGB-encoded color around `point` (0...1 from the top left of
    /// the cropped photo), for Color Grading's color picker.
    public func color(at point: CGPoint, settings: DevelopSettings, radius: Int = 2) -> SIMD3<Double>? {
        guard let image = image(with: settings) else { return nil }
        let extent = image.extent
        let x = extent.minX + point.x * extent.width, y = extent.minY + (1 - point.y) * extent.height
        let side = CGFloat(radius * 2 + 1)
        let region = CGRect(x: (x - side / 2).rounded(.down), y: (y - side / 2).rounded(.down), width: side, height: side)
            .intersection(extent.integral)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        let width = Int(region.width), height = Int(region.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            renderer.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: region,
                                    format: .RGBAf, colorSpace: DevelopRenderer.sRGB)
        }
        var sum = SIMD3<Double>(0, 0, 0)
        for i in 0..<(width * height) {
            sum += SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2]))
        }
        let mean = sum / Double(width * height)
        return SIMD3(min(1, max(0, mean.x)), min(1, max(0, mean.y)), min(1, max(0, mean.z)))
    }

    /// Rendered in sRGB, for measuring colors (Match Look).
    public func renderSRGB(_ settings: DevelopSettings) -> CGImage? {
        guard let image = image(with: settings) else { return nil }
        return renderer.cgImage(image, colorSpace: DevelopRenderer.sRGB)
    }

    /// Rendered for display in Display P3.
    public func render(_ settings: DevelopSettings, cropping: Bool = true, overlay: UUID? = nil,
                       preview: SliderPreview? = nil) -> CGImage? {
        guard let image = image(with: settings, cropping: cropping, overlay: overlay, preview: preview) else { return nil }
        return renderer.cgImage(image)
    }

    /// Rendered for display in Display P3 with Lightroom's clipping overlay painted in during the
    /// same render, and `plain`, the photo without the overlay for the histogram. Without the
    /// overlay `plain` is the image itself; with it, a copy at most `sampleSize` pixels long, made
    /// from the render Core Image just cached instead of rendering the photo again.
    public func renderForDisplay(_ settings: DevelopSettings, cropping: Bool = true, overlay: UUID? = nil,
                                 preview: SliderPreview? = nil, shadowClipping: Bool = false,
                                 highlightClipping: Bool = false,
                                 sampleSize: Int = Histogram.sampleSize) -> (image: CGImage, plain: CGImage)? {
        guard var image = image(with: settings, cropping: cropping, overlay: overlay, preview: preview) else { return nil }
        guard shadowClipping || highlightClipping else {
            guard let cgImage = renderer.cgImage(image) else { return nil }
            return (cgImage, cgImage)
        }
        image = image.insertingIntermediate(cache: true)
        let painted = ClippingOverlay.apply(to: image, shadows: shadowClipping, highlights: highlightClipping,
                                            shownIn: DevelopRenderer.displaySpace)
        guard let shown = renderer.cgImage(painted) else { return nil }
        let extent = image.extent
        let factor = min(1, CGFloat(sampleSize) / max(1, max(extent.width, extent.height)))
        var small = image
        if factor < 1 {
            small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor,
                                                                                 kCIInputAspectRatioKey: 1])
        }
        return (shown, renderer.cgImage(small) ?? shown)
    }
}
