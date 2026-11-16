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
                                        preview: SliderPreview? = nil, cacheStages: Bool = false) -> CIImage {
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

        // Calibration (AT-069) reshapes the profile's primaries, so it comes before every other
        // color and tone step, as in Lightroom.
        image = Calibration.apply(image, settings: settings)

        // Highlights and Shadows: local, judged by an edge-aware base (see LocalContrast).
        image = LocalContrast.toneRegions(image, highlights: settings.highlights / 100, shadows: settings.shadows / 100,
                                          scale: scale, cacheStage: cacheStages)

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
            image = LocalContrast.apply(image, amount: settings.clarity / 100, kind: LocalContrast.clarity, scale: scale,
                                        cacheStage: cacheStages)
        }
        if settings.texture != 0 {
            image = LocalContrast.apply(image, amount: settings.texture / 100, kind: LocalContrast.texture, scale: scale,
                                        cacheStage: cacheStages)
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
        if let overlay, let mask = (settings.masks + settings.lensBlurAreas).first(where: { $0.id == overlay }) {
            image = self.overlay(mask, on: image, base: beforeMasks, provider: masks)
        }
        switch preview {
        case .sharpenAmount: image = SliderPreview.grayscale(image)
        case .highlightClipping: image = SliderPreview.clipping(image, highlights: true)
        case .shadowClipping: image = SliderPreview.clipping(image, highlights: false)
        case .visualizeSpots(let amount): image = SpotRenderer.visualize(image, amount: amount)
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
    /// The Remove tool's spot shapes, drawn once per spot.
    private let spotCache = SpotShapeCache()
    /// Content-Aware Remove's fills, found once per spot and corrected photo.
    private lazy var spotFills = SpotFills(context: renderer.context, waits: !interactive)
    /// A number for each corrected photo's settings (`CorrectedKey`) that the spots were drawn
    /// on, so a fill is found again only when the photo under it changes. Most recent last.
    private var upstreamIDs: [(key: CorrectedKey, id: Int)] = []
    private var nextUpstreamID = 1
    /// Select Subject's and Select Object's masks on the corrected photo, by box, found once per
    /// lens geometry; a nil mask when Vision found nothing.
    private var subjectMasks: [DevelopSettings.MaskRect?: CIImage?] = [:]
    private var subjectKey: DevelopSettings?
    /// Select People's faces and skin on the corrected photo, found once per lens geometry.
    private var peopleFound: (key: DevelopSettings, skin: PeopleSkin?)?
    /// Fine Edges' foreground mattes on the corrected photo, by the square each was found in,
    /// for one lens geometry and one Fine Edges model (nil inside when it failed).
    private var fineMattes: [FineRegion: CIImage?] = [:]
    /// Squares whose matte is being found in the background (interactive sessions).
    private var finePending: Set<FineRegion> = []
    private var fineKey: DevelopSettings?
    private var fineModel: FineEdges.Model?
    /// Depth Range's depth of the corrected photo, found once per lens geometry (nil inside when
    /// the model failed), its map on the photo's frame, and whether it is being found in the
    /// background (interactive sessions).
    private var depthFound: (key: DevelopSettings, field: DepthMap.Field?, map: CIImage?)?
    /// Select Sky's mask from `depthFound`'s field, for the same lens geometry.
    private var skyFound: (key: DevelopSettings, mask: CIImage?)?
    private var depthPending: DevelopSettings?
    /// Pipeline step 1's results for the settings they were made from (see `CorrectedKey`), so a
    /// slider on any later panel doesn't decode the RAW and redo the lens corrections again.
    /// Two are kept, most recent last, so the Before view and the edit don't push each other out.
    private var correctedCache: [(key: CorrectedKey, image: CIImage)] = []
    /// Whether `correctedCache` is used; see `DevelopRenderer.session(for:maxPixelSize:interactive:)`.
    private let interactive: Bool
    /// Apple's own noise reduction for this RAW file (its defaults), turned off while AI Denoise
    /// replaces it.
    private let nativeNoiseReduction: (luminance: Float, color: Float)
    /// The file as AI Denoise keys its noise pictures (`AIDenoise.Store.fileKey`).
    private let denoiseFile: String

    init?(url: URL, maxPixelSize: Int?, renderer: DevelopRenderer, interactive: Bool = false) {
        self.url = url
        self.renderer = renderer
        self.interactive = interactive
        denoiseFile = AIDenoise.Store.fileKey(url)
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
            nativeNoiseReduction = (raw.luminanceNoiseReductionAmount, raw.colorNoiseReductionAmount)
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
            nativeNoiseReduction = (0, 0)
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
        // The Remove tool's spots, before every tone and color step (so a slider never redraws
        // them) and before the masks, which then see the cleaned photo.
        if !settings.spots.isEmpty {
            image = SpotRenderer.apply(settings.spots, to: image, cache: spotCache, fills: spotFills,
                                       upstream: upstreamID(for: settings))
        }
        let sourceExtent = image.extent
        let source = image
        let key = settings.lensGeometryKey
        let crop = settings.crop
        // Visualize Depth: the depth map in color instead of the photo, cropped like it.
        if preview == .visualizeDepth {
            let map = depthMap(of: source, key: key)
            let view = map.flatMap { LensBlur.visualize(depth: $0, settings: settings) }
                ?? CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18)).cropped(to: sourceExtent)
            guard let crop else { return view }
            return DevelopRenderer.applyGeometry(crop, to: view, cropping: cropping)
        }
        // Lens Blur, on the uncropped photo in linear light, before every tone and color step (so
        // highlights spread as light does); masks below still see the sharp `source`. Until the
        // depth is found in the background the photo shows unblurred.
        // Masks' parts on the upright, uncropped photo (luminance ranges are worked out later,
        // from the photo they see).
        let sourceProvider: MaskProvider = { [self] component in
            if case .luminance = component.shape { return nil }
            return DevelopRenderer.sourceMask(component, extent: sourceExtent,
                                              subject: { self.subject(of: source, key: key, box: $0) },
                                              people: { self.people(of: source, key: key, selection: $0) },
                                              fine: { self.fineMatte(of: source, key: key, outline: $0) },
                                              depth: { self.depthMap(of: source, key: key) },
                                              sky: { self.skyMask(of: source, key: key) },
                                              guide: source, brushCache: brushCache)
        }
        if LensBlur.isOn(settings), let depth = depthMap(of: source, key: key) {
            // Focus and Blur areas: masks with Lens Focus, on the same uncropped frame.
            let areas = LensBlur.areas(settings, on: source, provider: sourceProvider)
            image = LensBlur.apply(source, depth: depth, settings: settings, areas: areas)
        }
        if let crop {
            image = DevelopRenderer.applyGeometry(crop, to: image, cropping: cropping)
        }
        let provider: MaskProvider = { component in
            guard let mask = sourceProvider(component) else { return nil }
            guard let crop else { return mask }
            return DevelopRenderer.applyGeometry(crop, to: mask, cropping: cropping)
        }
        let adjusted = DevelopRenderer.applyAdjustments(settings, to: image, scale: renderScale, masks: provider,
                                                        overlay: overlay, preview: preview, cacheStages: interactive)
        guard !cropping, let crop else { return adjusted }
        // Vignetting and grain would paint the crop tool's empty corners; cut them again.
        return DevelopRenderer.straightenedOutline(crop, size: crop.orientedSize(sourceExtent.size), of: adjusted)
    }

    /// The context this session renders with.
    var renderContext: CIContext { renderer.context }

    /// The photo masks are found on: corrected, with every Remove tool spot, upright and
    /// uncropped (the `source` Select Subject and Color Range see).
    func maskSourceImage(_ settings: DevelopSettings) -> CIImage? {
        let settings = settings.applyingPanelSwitches()
        lock.lock()
        defer { lock.unlock() }
        guard var image = corrected(settings) else { return nil }
        if !settings.spots.isEmpty {
            image = SpotRenderer.apply(settings.spots, to: image, cache: spotCache, fills: spotFills,
                                       upstream: upstreamID(for: settings))
        }
        return image
    }

    /// The corrected photo with the spots before spot `id` drawn on it, upright and uncropped:
    /// what that spot is filled from (Generative AI sends it to ComfyUI). Nil when `id` isn't one
    /// of the spots.
    func imageUnderSpot(_ id: UUID, settings: DevelopSettings) -> CIImage? {
        let settings = settings.applyingPanelSwitches()
        guard let index = settings.spots.firstIndex(where: { $0.id == id }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard var image = corrected(settings) else { return nil }
        let prior = Array(settings.spots[..<index])
        if !prior.isEmpty {
            image = SpotRenderer.apply(prior, to: image, cache: spotCache, fills: spotFills,
                                       upstream: upstreamID(for: settings))
        }
        return image
    }

    /// The number for the corrected photo `settings` make (see `upstreamIDs`). Call with the
    /// lock held.
    private func upstreamID(for settings: DevelopSettings) -> Int {
        let switched = settings.applyingPanelSwitches()
        let key = CorrectedKey(switched, view: .photo, denoised: isDenoised(switched))
        if let index = upstreamIDs.firstIndex(where: { $0.key == key }) {
            let found = upstreamIDs.remove(at: index)
            upstreamIDs.append(found)
            return found.id
        }
        let id = nextUpstreamID
        nextUpstreamID += 1
        upstreamIDs.append((key, id))
        if upstreamIDs.count > 16 { upstreamIDs.removeFirst() }
        return id
    }

    /// Pipeline step 1: decode with white balance and exposure, the profile, then the lens
    /// corrections (chromatic aberration, Defringe, vignetting, distortion) and the Transform.
    /// The result starts at the origin. Call with the lock held.
    private func corrected(_ settings: DevelopSettings, defringeView: Defringe.View = .photo) -> CIImage? {
        let settings = settings.applyingPanelSwitches()
        guard interactive else { return decodeAndCorrect(settings, defringeView: defringeView) }
        let key = CorrectedKey(settings, view: defringeView, denoised: isDenoised(settings))
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
        /// AI Denoise's Amount, and whether its noise picture was ready (it is found in the
        /// background, and the photo renders again once it is in).
        let aiDenoise: Double
        let denoised: Bool

        init(_ settings: DevelopSettings, view: Defringe.View, denoised: Bool = false) {
            // Lens profile corrections, lens vignetting and distortion, Upright and Transform.
            geometry = settings.lensGeometryKey
            temperature = settings.temperature
            tint = settings.tint
            exposure = settings.exposure
            profile = settings.profile
            removeChromaticAberration = settings.removeChromaticAberration
            defringe = DevelopSettings.Parameter.allCases.filter(\.isDefringe).map { settings[$0] }
            self.view = view
            aiDenoise = settings[.aiDenoise]
            self.denoised = denoised
        }
    }

    /// Whether AI Denoise's noise picture for `settings` is ready (for `CorrectedKey`).
    private func isDenoised(_ settings: DevelopSettings) -> Bool {
        isRAW && settings[.aiDenoise] > 0
            && AIDenoise.store.cached(file: denoiseFile, profileCorrections: settings.lensProfileCorrections) != nil
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
            // AI Denoise (AT-067) replaces Apple's noise reduction once the photo's noise is found:
            // in the background while editing, before rendering in exports and previews.
            let amount = settings[.aiDenoise] / 100
            let residual = amount > 0
                ? AIDenoise.store.residual(for: url, file: denoiseFile, profileCorrections: settings.lensProfileCorrections,
                                           waits: !interactive, context: renderer.context)
                : nil
            let luminanceNR = residual == nil ? nativeNoiseReduction.luminance : 0
            let colorNR = residual == nil ? nativeNoiseReduction.color : 0
            if raw.isLuminanceNoiseReductionSupported, raw.luminanceNoiseReductionAmount != luminanceNR {
                raw.luminanceNoiseReductionAmount = luminanceNR
            }
            if raw.isColorNoiseReductionSupported, raw.colorNoiseReductionAmount != colorNR {
                raw.colorNoiseReductionAmount = colorNR
            }
            guard var output = raw.outputImage else { return nil }
            if let residual { output = residual.apply(to: output, amount: amount) }
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

    /// Select People's face and body skin, found by Vision once per lens geometry. Call with the
    /// lock held.
    private func peopleSkin(of source: CIImage, key: DevelopSettings) -> PeopleSkin? {
        if let peopleFound, peopleFound.key == key { return peopleFound.skin }
        let extent = source.extent
        let factor = min(1, Double(PeopleSkin.size) / Double(max(extent.width, extent.height)))
        let small = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let skin = renderer.context.createCGImage(small, from: small.extent.integral, format: .RGBA8,
                                                  colorSpace: DevelopRenderer.sRGB).flatMap(PeopleSkin.find)
        peopleFound = (key, skin)
        return skin
    }

    /// Fine Edges' foreground matte around `outline` (a Vision selection on the corrected
    /// photo's frame): the active model runs (at its 1024 or 2048 pixel square) on a square
    /// around the outline's bounds with 20% to spare, so a person who fills a third of the frame
    /// is seen at three times the detail of the whole photo. The result covers only that square.
    /// Found once per lens geometry, model and square. Nil when no model is downloaded, the model
    /// fails or the outline is empty.
    /// Call with the lock held.
    private func fineMatte(of source: CIImage, key: DevelopSettings, outline: CIImage) -> CIImage? {
        let model = FineEdges.active
        if fineKey != key || fineModel != model {
            fineMattes = [:]
            finePending = []
            fineKey = key
            fineModel = model
        }
        guard let model, let region = fineRegion(of: outline, extent: source.extent) else { return nil }
        let regionKey = FineRegion(region)
        if let cached = fineMattes[regionKey] { return cached }
        // Already being found in the background: render without it for now.
        if finePending.contains(regionKey) { return nil }
        let side = CGFloat(model.size)
        let square = source.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: side / region.width, y: side / region.height))
        guard let cgImage = renderer.context.createCGImage(square, from: CGRect(x: 0, y: 0, width: side, height: side),
                                                           format: .RGBA8, colorSpace: DevelopRenderer.sRGB)
        else { return nil }
        guard interactive else {
            // Export and other one-off renders wait for it.
            let matte = Self.placedMatte(FineEdges.matte(of: cgImage, model: model), size: model.size, in: region)
            fineMattes[regionKey] = matte
            return matte
        }
        // The model takes seconds (much longer the first time, while Core ML compiles it), so
        // the editor doesn't wait: the mask shows without Fine Edges, and once the matte is in,
        // `FineEdges.matteReady` asks for a new render, which picks it up from the cache.
        finePending.insert(regionKey)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matte = Self.placedMatte(FineEdges.matte(of: cgImage, model: model), size: model.size, in: region)
            guard let self else { return }
            self.lock.lock()
            if self.fineKey == key, self.fineModel == model, self.finePending.remove(regionKey) != nil {
                if self.fineMattes.count >= 4 { self.fineMattes.removeAll() }
                self.fineMattes[regionKey] = matte
            }
            self.lock.unlock()
            DispatchQueue.main.async { NotificationCenter.default.post(name: FineEdges.matteReady, object: nil) }
        }
        return nil
    }

    /// Depth Range's depth map of the corrected photo on its frame (0 nearest to 1 farthest),
    /// with its edges moved onto the photo's own edges (the model sees the photo at about 518
    /// pixels, so its edges are soft). Found once per lens geometry: in interactive sessions in
    /// the background (the mask is empty until `DepthMap.ready` asks for a new render), in
    /// exports right away. Nil when the model isn't downloaded or failed. Call with the lock held.
    private func depthMap(of source: CIImage, key: DevelopSettings) -> CIImage? {
        guard DepthMap.isInstalled else { return nil }
        if let depthFound, depthFound.key == key { return depthFound.map }
        guard interactive else {
            let field = estimateDepth(of: source)
            let map = field.flatMap { Self.placedDepth($0, on: source) }
            depthFound = (key, field, map)
            return map
        }
        if depthPending == key { return nil }
        depthPending = key
        guard let cgImage = depthInput(of: source) else { return nil }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let field = DepthMap.estimate(cgImage)
            guard let self else { return }
            self.lock.lock()
            if self.depthPending == key {
                self.depthPending = nil
                self.depthFound = (key, field, field.flatMap { Self.placedDepth($0, on: source) })
            }
            self.lock.unlock()
            DispatchQueue.main.async { NotificationCenter.default.post(name: DepthMap.ready, object: nil) }
        }
        return nil
    }

    /// Select Sky's mask on the corrected photo's frame, from the depth field (found as for Depth
    /// Range: in the background while editing). Nil until the depth is in, or without the model.
    /// Call with the lock held.
    private func skyMask(of source: CIImage, key: DevelopSettings) -> CIImage? {
        if let skyFound, skyFound.key == key { return skyFound.mask }
        _ = depthMap(of: source, key: key)
        guard let depthFound, depthFound.key == key else { return nil }
        var mask: CIImage?
        if let field = depthFound.field {
            mask = DepthMap.Field.image(field.sky, width: field.width, height: field.height, on: source.extent)?
                .insertingIntermediate(cache: true)
        }
        skyFound = (key, mask)
        return mask
    }

    /// Whether Select Sky finds any sky (for the panel's message). Finds the depth first if
    /// needed, so call it off the main thread. Nil when the depth model isn't downloaded or failed.
    public func findsSky(settings: DevelopSettings) -> Bool? {
        // Finds the depth if it isn't in yet.
        guard depths(in: DevelopSettings.MaskRect(x: 0, y: 0, width: 0, height: 0), settings: settings) != nil else { return nil }
        let key = settings.applyingPanelSwitches().lensGeometryKey
        lock.lock()
        defer { lock.unlock() }
        guard let field = depthFound?.key == key ? depthFound?.field : nil else { return nil }
        return field.sky.contains { $0 > 0.5 }
    }

    /// The photo the depth model sees: the corrected photo at about 1036 pixels on its long edge
    /// (the model shrinks it to its own size), as sRGB, in whole pixels. Shrunk with Lanczos,
    /// which averages the pixels it drops (a plain scale transform samples them, so noise reached
    /// the model at full strength), and cropped to whole pixels: the scaled size is fractional
    /// (6064 × 4040 → 1036 × 690.2), and the old half-covered top row came out dark, which stopped
    /// Select Sky at its first row (Rosh's Eiffel Tower photo, Nov 15, 2026).
    private func depthInput(of source: CIImage) -> CGImage? {
        let extent = source.extent
        let factor = min(1, 1036 / max(extent.width, extent.height))
        var small = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if factor < 1 {
            // Clamped first, so the filter doesn't darken the border with the empty space outside;
            // cropped to whole pixels, so no row or column is part empty.
            let frame = CGRect(x: 0, y: 0, width: (extent.width * factor).rounded(.down),
                               height: (extent.height * factor).rounded(.down))
            small = small.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
                .cropped(to: frame)
        }
        return renderer.context.createCGImage(small, from: small.extent.integral, format: .RGBA8,
                                              colorSpace: DevelopRenderer.sRGB)
    }

    private func estimateDepth(of source: CIImage) -> DepthMap.Field? {
        depthInput(of: source).flatMap(DepthMap.estimate)
    }

    /// `field` stretched over the photo's frame, its edges snapped to the photo's (Refine Edge's
    /// guided filter, radius 0.5% of the long edge), kept as a cached intermediate so a slider
    /// drag doesn't redo it.
    private static func placedDepth(_ field: DepthMap.Field, on source: CIImage) -> CIImage? {
        let extent = source.extent
        guard let map = field.image(on: extent) else { return nil }
        let longEdge = Double(max(extent.width, extent.height))
        let refined = MaskGuidedFilter.apply(mask: map, guide: source, radius: max(1, 0.005 * longEdge), epsilon: 0.0004,
                                             extent: extent) ?? map
        return refined.cropped(to: extent).insertingIntermediate(cache: true)
    }

    /// The depths inside `box` (top-left fractions of the upright, uncropped photo), 0 nearest
    /// to 1 farthest, for a Depth Range pick; finds the depth first if needed (under a second),
    /// so call it off the main thread. Nil when the model isn't downloaded or failed.
    public func depths(in box: DevelopSettings.MaskRect, settings: DevelopSettings) -> [Float]? {
        guard DepthMap.isInstalled, let source = maskSourceImage(settings) else { return nil }
        let key = settings.applyingPanelSwitches().lensGeometryKey
        lock.lock()
        let known = depthFound?.key == key ? depthFound?.field : nil
        let wasFound = depthFound?.key == key
        lock.unlock()
        if wasFound { return known?.values(in: box) }
        guard let field = estimateDepth(of: source) else { return nil }
        lock.lock()
        if depthFound?.key != key {
            depthFound = (key, field, Self.placedDepth(field, on: source))
            if depthPending == key { depthPending = nil }
        }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: DepthMap.ready, object: nil) }
        return field.values(in: box)
    }

    /// Lens Blur's focus picker: the depths in a small square around `point` (0...1 from the top
    /// left of the cropped photo, as the photo view gives clicks), 0 nearest to 1 farthest. Finds
    /// the depth first if needed, so call it off the main thread. Nil without the depth model.
    public func focusDepths(at point: CGPoint, settings: DevelopSettings) -> [Float]? {
        guard let size = maskSourceImage(settings)?.extent.size, size.width > 0, size.height > 0 else { return nil }
        var spot = CGPoint(x: point.x * size.width, y: point.y * size.height)
        if let crop = settings.applyingPanelSwitches().crop {
            let output = crop.outputSize(size)
            spot = crop.sourcePoint(fromOutput: CGPoint(x: point.x * output.width, y: point.y * output.height),
                                    sourceSize: size)
        }
        let x = Double(spot.x / size.width), y = Double(spot.y / size.height)
        let half = 0.012
        let box = DevelopSettings.MaskRect(x: min(1, max(0, x - half)), y: min(1, max(0, y - half)),
                                           width: 2 * half, height: 2 * half)
        return depths(in: box, settings: settings)
    }

    /// Lens Blur's Subject focus: the depths under the photo's subject, as Vision's Select Subject
    /// finds it, 0 nearest to 1 farthest. Finds the depth and the subject first if needed, so call
    /// it off the main thread. Nil without the depth model or when no subject is found.
    public func subjectDepths(settings: DevelopSettings) -> [Float]? {
        guard depths(in: DevelopSettings.MaskRect(x: 0, y: 0, width: 0, height: 0), settings: settings) != nil,
              let source = maskSourceImage(settings) else { return nil }
        let key = settings.applyingPanelSwitches().lensGeometryKey
        lock.lock()
        let field = depthFound?.key == key ? depthFound?.field : nil
        let mask = field == nil ? nil : subject(of: source, key: key, box: nil)
        lock.unlock()
        guard let field, let mask else { return nil }
        // The mask on the depth's grid, rows from the top as the field's are.
        let extent = source.extent
        let small = mask.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(field.width) / extent.width,
                                               y: CGFloat(field.height) / extent.height))
        var pixels = [Float](repeating: 0, count: field.width * field.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            renderer.context.render(small, toBitmap: buffer.baseAddress!, rowBytes: field.width * 16,
                                    bounds: CGRect(x: 0, y: 0, width: field.width, height: field.height),
                                    format: .RGBAf, colorSpace: nil)
        }
        // Core Image's bitmap rows run from the top of `bounds`.
        var found: [Float] = []
        for index in 0..<(field.width * field.height) where pixels[index * 4] > 0.5 {
            found.append(field.values[index])
        }
        return found.count >= 4 ? found : nil
    }

    /// The model's values as a mask over `region` of the photo's frame; nil stays nil.
    private static func placedMatte(_ values: [Float]?, size: Int, in region: CGRect) -> CIImage? {
        let side = CGFloat(size)
        guard let values, let gray = PeopleSkin.grayImage(values, width: size, height: size)
        else { return nil }
        return DevelopRenderer.rawMask(gray)
            .transformed(by: CGAffineTransform(scaleX: region.width / side, y: region.height / side))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
            .cropped(to: region)
    }

    /// The square Fine Edges looks at for `outline`: its bounds (where it is above half, found on
    /// a copy 256 pixels long) with 20% more on every side, widened to a square and kept inside
    /// the photo. Rounded to whole 1/256ths of the photo so it stays the same from render to
    /// render. Nil when the outline is empty.
    private func fineRegion(of outline: CIImage, extent: CGRect) -> CGRect? {
        let factor = min(1, 256 / max(extent.width, extent.height))
        let w = max(1, Int((extent.width * factor).rounded())), h = max(1, Int((extent.height * factor).rounded()))
        let small = outline.cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
        var bytes = [UInt8](repeating: 0, count: w * h)
        renderer.context.render(small, toBitmap: &bytes, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                format: .L8, colorSpace: nil)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where bytes[y * w + x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows run from the top; Core Image's y from the bottom.
        var box = CGRect(x: CGFloat(minX), y: CGFloat(h - 1 - maxY), width: CGFloat(maxX - minX + 1),
                         height: CGFloat(maxY - minY + 1))
        box = box.insetBy(dx: -box.width * 0.2, dy: -box.height * 0.2)
        let side = max(box.width, box.height)
        // Whole pixels of the small copy, so the square stays the same from render to render.
        box = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        let region = CGRect(x: extent.minX + box.minX / factor, y: extent.minY + box.minY / factor,
                            width: box.width / factor, height: box.height / factor)
            .intersection(extent).integral
        return region.width >= 16 && region.height >= 16 ? region : nil
    }

    /// Select People's mask on the corrected photo's frame.
    private func people(of source: CIImage, key: DevelopSettings,
                        selection: DevelopSettings.PeopleSelection) -> CIImage? {
        guard let skin = peopleSkin(of: source, key: key), let mask = skin.mask(selection) else { return nil }
        let image = DevelopRenderer.rawMask(mask)
        let extent = source.extent
        return image
            .transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width, y: extent.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// The faces Select People finds, left to right, 0 to 1 from the top left of the upright,
    /// uncropped photo (one per person it can select). Empty when it finds no one.
    public func peopleFaces(settings: DevelopSettings) -> [CGRect] {
        let settings = settings.applyingPanelSwitches()
        lock.lock()
        defer { lock.unlock() }
        guard let source = corrected(settings) else { return [] }
        return peopleSkin(of: source, key: settings.lensGeometryKey)?.people.map(\.face) ?? []
    }

    /// Select People's mask on the cropped photo, as `renderSRGB` frames it (white is skin), or nil
    /// when Vision finds no one. Match Look measures skin with it, so it sees the same skin the
    /// "Match Look: Skin" mask adjusts.
    public func peopleMask(_ settings: DevelopSettings,
                           selection: DevelopSettings.PeopleSelection = .init(feather: 0)) -> CGImage? {
        let settings = settings.applyingPanelSwitches()
        lock.lock()
        defer { lock.unlock() }
        guard let source = corrected(settings) else { return nil }
        let key = settings.lensGeometryKey
        let component = DevelopSettings.MaskComponent(.people(selection))
        guard var mask = DevelopRenderer.sourceMask(component, extent: source.extent, subject: nil,
                                                    people: { self.people(of: source, key: key, selection: $0) },
                                                    fine: { self.fineMatte(of: source, key: key, outline: $0) },
                                                    guide: source, brushCache: brushCache) else { return nil }
        if let crop = settings.crop { mask = DevelopRenderer.applyGeometry(crop, to: mask) }
        return renderer.context.createCGImage(mask, from: mask.extent.integral, format: .L8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.linearGray), deferred: false)
    }

    /// Whether Vision finds anything for a Select Subject or Select Object part, so the Masks
    /// panel can say so instead of leaving an empty mask.
    public func findsSubject(_ selection: DevelopSettings.Selection, settings: DevelopSettings) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let source = corrected(settings) else { return false }
        return subject(of: source, key: settings.lensGeometryKey, box: selection.box) != nil
    }

    /// Select Subject's mask on the cropped photo, as `renderSRGB` frames it (white is the
    /// subject), or nil when Vision finds nothing. Match Look's Subject & Background measures the
    /// subject and the background with it, so it sees the same subject the mask it adds will.
    public func subjectMask(_ settings: DevelopSettings, feather: Double = LookMatcher.subjectFeather) -> CGImage? {
        let settings = settings.applyingPanelSwitches()
        lock.lock()
        defer { lock.unlock() }
        guard let source = corrected(settings) else { return nil }
        let key = settings.lensGeometryKey
        let component = DevelopSettings.MaskComponent(.subject(DevelopSettings.Selection(feather: feather)))
        guard var mask = DevelopRenderer.sourceMask(component, extent: source.extent,
                                                    subject: { self.subject(of: source, key: key, box: $0) },
                                                    fine: { self.fineMatte(of: source, key: key, outline: $0) },
                                                    guide: source, brushCache: brushCache) else { return nil }
        if let crop = settings.crop { mask = DevelopRenderer.applyGeometry(crop, to: mask) }
        // Mask values are stored as is, so linear gray keeps them unchanged.
        return renderer.context.createCGImage(mask, from: mask.extent.integral, format: .L8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.linearGray), deferred: false)
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

/// A Fine Edges square in whole pixels, as a cache key.
struct FineRegion: Hashable {
    let x, y, width, height: Int

    init(_ rect: CGRect) {
        x = Int(rect.minX); y = Int(rect.minY); width = Int(rect.width); height = Int(rect.height)
    }
}
