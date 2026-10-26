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

    // MARK: Adjustments after decode

    /// Steps 2 to 4 of the pipeline; white balance and exposure happen at decode.
    public static func applyAdjustments(_ settings: DevelopSettings, to input: CIImage) -> CIImage {
        var image = input

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
        return image
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

    /// The tone curve sampled as RGB triples for CIColorCurves.
    static func toneCurveLUT(_ settings: DevelopSettings, samples: Int = 1024) -> [Float]? {
        guard let points = toneCurvePoints(settings) else { return nil }
        var lut = [Float]()
        lut.reserveCapacity(samples * 3)
        for i in 0..<samples {
            let y = Float(evaluateCurve(points, at: Double(i) / Double(samples - 1)))
            lut.append(contentsOf: [y, y, y])
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
    private let lock = NSLock()

    init?(url: URL, maxPixelSize: Int?, renderer: DevelopRenderer) {
        self.url = url
        self.renderer = renderer
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .rawImage) == true, let raw = CIRAWFilter(imageURL: url) {
            isRAW = true
            rawFilter = raw
            baseImage = nil
            if let maxPixelSize {
                let longEdge = max(raw.nativeSize.width, raw.nativeSize.height)
                if longEdge > 0 { raw.scaleFactor = Float(min(1, Double(maxPixelSize) / Double(longEdge))) }
            }
            asShotTemperature = Double(raw.neutralTemperature)
            asShotTint = Double(raw.neutralTint)
        } else {
            guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            if let maxPixelSize {
                let longEdge = max(image.extent.width, image.extent.height)
                if longEdge > CGFloat(maxPixelSize) {
                    let scale = CGFloat(maxPixelSize) / longEdge
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
            }
            isRAW = false
            rawFilter = nil
            baseImage = image
            asShotTemperature = 6500
            asShotTint = 0
        }
    }

    /// The developed image in the working space.
    public func image(with settings: DevelopSettings) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        var image: CIImage
        if let raw = rawFilter {
            raw.neutralTemperature = Float(settings.temperature ?? asShotTemperature)
            raw.neutralTint = Float(asShotTint + settings.tint)
            raw.exposure = Float(settings.exposure)
            guard let output = raw.outputImage else { return nil }
            image = output
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
        return DevelopRenderer.applyAdjustments(settings, to: image)
    }

    /// Rendered for display in Display P3.
    public func render(_ settings: DevelopSettings) -> CGImage? {
        guard let image = image(with: settings) else { return nil }
        return renderer.cgImage(image)
    }
}
