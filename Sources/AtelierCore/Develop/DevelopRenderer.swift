import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders develop settings on the GPU with Core Image, following the PRD pipeline order:
/// RAW decode with white balance and exposure, then highlights and shadows, tone (contrast,
/// whites, blacks) in a perceptual space, then color (vibrance, saturation).
public final class DevelopRenderer: @unchecked Sendable {
    public static let shared = DevelopRenderer()

    public let context: CIContext
    /// Linear Rec. 2020 working space, as in the PRD.
    public static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    public static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Camera matches by file and modification date; see `CameraMatch`.
    let cameraMatches = NSCache<NSString, CameraMatchBox>()

    public init() {
        context = CIContext(options: [
            .workingColorSpace: Self.workingSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
        ])
    }

    /// Opens a photo for editing. Keep the session while the photo is on screen; it reuses
    /// the decoded source between slider changes.
    public func session(for url: URL, maxPixelSize: Int?) -> DevelopSession? {
        DevelopSession(url: url, maxPixelSize: maxPixelSize, renderer: self)
    }

    public func cgImage(_ image: CIImage, colorSpace: CGColorSpace = DevelopRenderer.displaySpace) -> CGImage? {
        context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: colorSpace)
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
        }
        guard cropping else { return image }
        // The crop is measured from the top left; Core Image's y axis points up.
        let rect = CGRect(x: crop.x * size.width, y: (1 - crop.y - crop.height) * size.height,
                          width: crop.width * size.width, height: crop.height * size.height).integral
        image = image.cropped(to: rect)
        return image.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    // MARK: Adjustments after decode

    /// Steps 2 to 7 of the pipeline; white balance and exposure happen at decode.
    /// `scale` is the rendered size relative to the full-size photo, so pixel radii such as
    /// sharpening look the same on the live proxy and in an export. `masks` supplies the masks'
    /// drawn parts lined up with the crop; `overlay` names a mask to tint red on top.
    public static func applyAdjustments(_ settings: DevelopSettings, to input: CIImage, scale: Double = 1,
                                        masks: MaskProvider? = nil, overlay: UUID? = nil) -> CIImage {
        var image = input
        let extent = input.extent
        let longEdge = Double(max(extent.width, extent.height))

        // Highlights and shadows. CIHighlightShadowAdjust only recovers highlights, so positive
        // highlights are handled by the tone curve below.
        if settings.highlights < 0 || settings.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(1 + min(0, settings.highlights) / 100)
            filter.shadowAmount = Float(settings.shadows / 100)
            filter.radius = 0
            image = filter.outputImage ?? image
        }

        // Tone curve, applied in sRGB-encoded values so contrast behaves perceptually.
        // CIColorCurves names its color space explicitly, so no gamma round trip is needed.
        if let lut = toneCurveLUT(settings) {
            let filter = CIFilter.colorCurves()
            filter.inputImage = image
            filter.curvesData = lut.withUnsafeBufferPointer { Data(buffer: $0) }
            filter.curvesDomain = CIVector(x: 0, y: 1)
            filter.colorSpace = sRGB
            image = filter.outputImage ?? image
        }

        if settings.dehaze != 0 {
            image = dehaze(image, amount: settings.dehaze / 100)
        }
        // Clarity works on midtone local contrast with a wide radius, texture on fine detail.
        if settings.clarity != 0 {
            image = localContrast(image, amount: settings.clarity / 100 * 0.6, radius: longEdge * 0.012, extent: extent)
        }
        if settings.texture != 0 {
            image = localContrast(image, amount: settings.texture / 100 * 0.5, radius: max(1, longEdge * 0.003),
                                  extent: extent)
        }

        if settings.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(settings.vibrance / 100)
            image = filter.outputImage ?? image
        }
        if settings.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(1 + settings.saturation / 100)
            filter.brightness = 0
            filter.contrast = 1
            image = filter.outputImage ?? image
        }

        // HSL and color grading share one color cube in sRGB-encoded values.
        if let cube = ColorLUT.cube(for: settings) {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(ColorLUT.dimension)
            filter.cubeData = cube
            filter.colorSpace = sRGB
            image = filter.outputImage ?? image
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
        if settings.sharpening > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(settings.sharpening / 150 * 1.2)
            filter.radius = Float(max(0.3, settings.sharpenRadius * scale * 1.5))
            image = filter.outputImage?.cropped(to: extent) ?? image
        }

        // Local adjustments, before vignetting and grain.
        let beforeMasks = image
        if !settings.masks.isEmpty {
            image = applyMasks(settings, to: image, scale: scale, masks: masks)
        }

        // Effects
        if settings.vignette != 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = image
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            let diagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2
            filter.radius = Float(diagonal * (0.35 + settings.vignetteMidpoint / 100 * 0.6))
            filter.falloff = 0.6
            filter.intensity = Float(-settings.vignette / 100)
            image = filter.outputImage?.cropped(to: extent) ?? image
        }
        if settings.grain > 0 {
            image = addGrain(image, amount: settings.grain / 100, size: settings.grainSize / 100, scale: scale,
                             extent: extent)
        }
        if let overlay, let mask = settings.masks.first(where: { $0.id == overlay }) {
            image = self.overlay(mask, on: image, base: beforeMasks, provider: masks)
        }
        return image
    }

    /// Removes (positive) or adds (negative) a flat veil of haze, then restores saturation.
    static func dehaze(_ image: CIImage, amount: Double) -> CIImage {
        let airlight = 0.18
        let gain: Double, bias: Double
        if amount > 0 {
            let k = 0.35 * amount
            gain = 1 / (1 - k)
            bias = -k * airlight / (1 - k)
        } else {
            let k = 0.35 * -amount
            gain = 1 - k
            bias = k * airlight
        }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        let color = CIFilter.colorControls()
        color.inputImage = matrix.outputImage
        color.saturation = Float(1 + 0.25 * amount)
        color.brightness = 0
        color.contrast = 1
        return color.outputImage ?? image
    }

    /// Unsharp mask for positive amounts, a blend toward a blurred copy for negative ones.
    static func localContrast(_ image: CIImage, amount: Double, radius: Double, extent: CGRect) -> CIImage {
        let source = image.clampedToExtent()
        if amount > 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = source
            filter.radius = Float(radius)
            filter.intensity = Float(amount)
            return filter.outputImage?.cropped(to: extent) ?? image
        }
        let blurred = source.applyingGaussianBlur(sigma: radius / 2).cropped(to: extent)
        return mix(image, blurred, amount: min(1, -amount * 1.2))
    }

    static func mix(_ image: CIImage, _ other: CIImage, amount: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = image
        filter.targetImage = other
        filter.time = Float(amount)
        return filter.outputImage ?? image
    }

    /// Film-like monochrome grain, multiplied in so blacks stay black.
    static func addGrain(_ image: CIImage, amount: Double, size: Double, scale: Double, extent: CGRect) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let grainScale = max(0.5, (1 + size * 3) * scale)
        let strength = amount * 0.35
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = noise
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        matrix.rVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 1 - strength / 2, y: 1 - strength / 2, z: 1 - strength / 2, w: 1)
        guard let grain = matrix.outputImage?.cropped(to: extent) else { return image }
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = grain
        multiply.backgroundImage = image
        return multiply.outputImage?.cropped(to: extent) ?? image
    }

    /// Control points of the tone curve in sRGB-encoded values, or nil when it is the identity.
    public static func toneCurvePoints(_ settings: DevelopSettings) -> [CGPoint]? {
        let c = settings.contrast / 100
        let h = max(0, settings.highlights) / 100
        let w = settings.whites / 100
        let b = settings.blacks / 100
        guard c != 0 || h != 0 || w != 0 || b != 0 else { return nil }
        return [
            CGPoint(x: max(0, -b) * 0.1, y: max(0, b) * 0.1),
            CGPoint(x: 0.25, y: 0.25 - c * 0.08),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: min(1, 0.75 + c * 0.08 + h * 0.08)),
            CGPoint(x: 1 - max(0, w) * 0.1, y: 1 - max(0, -w) * 0.1),
        ]
    }

    static let curveRegions: [(DevelopSettings.Parameter, Double)] = [
        (.curveShadows, 0.125), (.curveDarks, 0.375), (.curveLights, 0.625), (.curveHighlights, 0.875),
    ]

    public static func hasToneCurve(_ settings: DevelopSettings) -> Bool {
        toneCurvePoints(settings) != nil || curveRegions.contains { settings[$0.0] != 0 } || settings.hasPointCurve
    }

    /// A point curve evaluated with the same monotone spline as the tone curve.
    public static func pointCurveValue(_ points: [DevelopSettings.CurvePoint], at x: Double) -> Double {
        guard points.count >= 2 else { return x }
        return evaluateCurve(points.map { CGPoint(x: $0.x, y: $0.y) }, at: x)
    }

    /// The full tone curve at `x` (sRGB-encoded 0...1): Basic tone plus the Tone Curve panel's
    /// region sliders, each a smooth bump over its quarter of the range.
    public static func toneCurveValue(_ settings: DevelopSettings, at x: Double) -> Double {
        var y = toneCurvePoints(settings).map { evaluateCurve($0, at: x) } ?? x
        for (parameter, center) in curveRegions {
            let amount = settings[parameter] / 100
            guard amount != 0 else { continue }
            var weight = max(0, 1 - abs(x - center) / 0.25)
            weight = weight * weight * (3 - 2 * weight)
            y += amount * 0.12 * weight
        }
        return min(1, max(0, y))
    }

    /// The tone curve sampled as RGB triples for CIColorCurves: Basic and region tone (never
    /// decreasing, so tones keep their order), then the RGB point curve, then each channel's.
    static func toneCurveLUT(_ settings: DevelopSettings, samples: Int = 1024) -> [Float]? {
        guard hasToneCurve(settings) else { return nil }
        let master = settings.points(for: .rgb)
        let channels = [settings.points(for: .red), settings.points(for: .green), settings.points(for: .blue)]
        var lut = [Float]()
        lut.reserveCapacity(samples * 3)
        var previous = 0.0
        for i in 0..<samples {
            let base = max(previous, toneCurveValue(settings, at: Double(i) / Double(samples - 1)))
            previous = base
            let y = pointCurveValue(master, at: base)
            for points in channels {
                lut.append(Float(pointCurveValue(points, at: y)))
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

    init?(url: URL, maxPixelSize: Int?, renderer: DevelopRenderer) {
        self.url = url
        self.renderer = renderer
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
    /// to tint red, for the Masks panel's Show Overlay.
    public func image(with settings: DevelopSettings, cropping: Bool = true, overlay: UUID? = nil) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
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
        return DevelopRenderer.applyAdjustments(settings, to: image, scale: renderScale, masks: provider, overlay: overlay)
    }

    /// Pipeline step 1: decode with white balance and exposure, the profile, then the lens
    /// corrections and the Transform. The result starts at the origin. Call with the lock held.
    private func corrected(_ settings: DevelopSettings) -> CIImage? {
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
            if let temperature = settings.temperature, temperature != asShotTemperature || settings.tint != 0 {
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = image
                filter.neutral = CIVector(x: asShotTemperature, y: 0)
                filter.targetNeutral = CIVector(x: temperature, y: settings.tint)
                image = filter.outputImage ?? image
            } else if settings.tint != 0 {
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = image
                filter.neutral = CIVector(x: asShotTemperature, y: 0)
                filter.targetNeutral = CIVector(x: asShotTemperature, y: settings.tint)
                image = filter.outputImage ?? image
            }
            if settings.exposure != 0 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = image
                filter.ev = Float(settings.exposure)
                image = filter.outputImage ?? image
            }
        }
        // Masks are drawn on the upright photo's frame, so start it at the origin.
        if image.extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let extent = image.extent
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

    /// Rendered for display in Display P3.
    public func render(_ settings: DevelopSettings, cropping: Bool = true, overlay: UUID? = nil) -> CGImage? {
        guard let image = image(with: settings, cropping: cropping, overlay: overlay) else { return nil }
        return renderer.cgImage(image)
    }
}
