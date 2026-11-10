import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd

/// A fast stand-in for the Develop renderer, for the steps Match Look moves after decode: the
/// tone curve (Basic tone, region and point curves), Saturation, HSL / Point Color with Color
/// Grading (one color mapping), and the Temp, Tint, Exposure and Saturation of Match Look's own
/// masks (Subject and the three skin masks).
///
/// A match tries many slider values and each try used to render the photo through the whole
/// pipeline. Here the photo is rendered once with those steps neutral (the stage), and every try
/// applies the same math to the stage's pixels on the CPU: the tone curve as the renderer's
/// hue-keeping kernel does, Saturation as Core Image's color controls, the color steps through
/// `ColorMix` and `ColorGrade` (the code behind the renderer's color cube), and each mask's
/// sliders blended in by its weight, which is measured once with a real render. White balance and
/// Exposure happen at RAW decode and are fitted with real renders before the stage is made; small
/// Exposure changes after that are emulated as a gain. Steps the stand-in leaves out (Dehaze,
/// Clarity, Texture, Vibrance and the photo's own masks are baked into the stage, so they run
/// before the curve here) make it approximate, so the match checks the result with a real render
/// at the end. A try the stand-in can't follow (another Temp or Tint, Black & White, other
/// masks) is rendered for real; see `follows`.
final class LookEmulator {
    let width: Int
    let height: Int
    /// The settings the stage was rendered with.
    let stageSettings: DevelopSettings
    /// The stage's sRGB-encoded colors, three per pixel.
    private let stage: [Float]
    /// Measures a mask's weight per pixel with real renders of the given settings; called once
    /// per mask shape.
    private let weigh: (DevelopSettings, DevelopSettings.Mask) -> [Float]?
    private struct Shape: Hashable {
        var id: UUID
        var components: [DevelopSettings.MaskComponent]
        var inverted: Bool
    }
    private var weights: [Shape: [Float]] = [:]
    private var cubeKey: [Double]?
    private var cube: [SIMD3<Float>] = []
    private var whiteBalances: [String: [SIMD3<Double>]] = [:]
    /// How many tries it has emulated, for the match's log.
    private(set) var tries = 0

    static let cubeSize = 33

    /// The masks the stand-in applies itself; the photo's own masks stay in the stage.
    static func isEmulated(_ mask: DevelopSettings.Mask) -> Bool {
        LookMatch.skinMaskNames.contains(mask.name) || mask.name == LookMatch.subjectMaskName
    }

    /// The settings to render the stage with: `settings` with every step the stand-in emulates
    /// set to neutral, and without Match Look's own masks.
    static func neutralStage(_ settings: DevelopSettings) -> DevelopSettings {
        var out = settings
        out.contrast = 0
        out.whites = 0
        out.blacks = 0
        for parameter in DevelopRenderer.curveRegions { out[parameter] = 0 }
        for channel in DevelopSettings.CurveChannel.allCases {
            out.setPoints(DevelopSettings.CurvePoint.identity, for: channel)
        }
        out.saturation = 0
        for parameter in DevelopSettings.Parameter.allCases where parameter.panel == .hsl || parameter.panel == .colorGrading {
            out[parameter] = parameter.defaultValue
        }
        out.masks.removeAll(where: isEmulated)
        return out
    }

    /// Whether `settings` differs from the stage only in what the stand-in emulates (Exposure
    /// counts as emulated: a small change after decode is close to a gain).
    func follows(_ settings: DevelopSettings) -> Bool {
        guard Self.supports(settings) else { return false }
        var stage = Self.neutralStage(settings)
        stage.exposure = stageSettings.exposure
        return stage == stageSettings && abs(settings.exposure - stageSettings.exposure) <= 1
    }

    /// Whether the stand-in can follow `settings` at all: in Black & White the B&W Mix decides
    /// the grays and Saturation does nothing, which it doesn't model.
    static func supports(_ settings: DevelopSettings) -> Bool { !settings.monochrome }

    /// `stage` is the photo rendered with `stageSettings` (sRGB).
    init?(stage image: CGImage, stageSettings: DevelopSettings,
          weigh: @escaping (DevelopSettings, DevelopSettings.Mask) -> [Float]?) {
        guard let data = LookSample.pixels(of: image) else { return nil }
        width = data.width
        height = data.height
        self.stageSettings = stageSettings
        self.weigh = weigh
        var colors = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            colors[i * 3] = Float(data.pixels[i * 4]) / 255
            colors[i * 3 + 1] = Float(data.pixels[i * 4 + 1]) / 255
            colors[i * 3 + 2] = Float(data.pixels[i * 4 + 2]) / 255
        }
        stage = colors
    }

    /// The photo as `settings` would render it, measured like a real render (`LookSample`).
    /// Temp and Tint must be the stage's; Exposure may differ a little.
    func sample(_ settings: DevelopSettings, area: CGRect? = nil) -> LookSample? {
        tries += 1
        let settings = settings.applyingPanelSwitches()
        let count = width * height
        let gain = Float(pow(2, settings.exposure - stageSettings.exposure))
        // Refine Saturation below 100 runs the RGB point curve on its own, as the renderer does.
        let refine = Float(min(1, max(0, settings[.curveRefineSaturation] / 100)))
        let master = settings.points(for: .rgb)
        let refinesPointCurve = refine < 1 && master != DevelopSettings.CurvePoint.identity
        let curve = DevelopRenderer.masterCurveLUT(settings, includingPointCurve: !refinesPointCurve)
        let pointCurve = refinesPointCurve ? DevelopRenderer.pointCurveLUT(master) : nil
        let channels = DevelopRenderer.channelCurvesLUT(settings)
        let saturation = settings.saturation / 100
        let color = colorCube(settings)
        var masks: [(weights: [Float], local: LocalSteps)] = []
        for mask in settings.masks where Self.isEmulated(mask) && !mask.isHidden && mask.hasAdjustments {
            guard let weights = weights(of: mask, in: settings) else { continue }
            masks.append((weights, localSteps(mask)))
        }

        var out = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            var c = SIMD3<Float>(stage[i * 3], stage[i * 3 + 1], stage[i * 3 + 2])
            if gain != 1 { c = Self.encode(Self.decode(c) * gain) }
            if let curve { c = Self.hueCurve(c, curve) }
            if let pointCurve { c = Self.hueCurve(c, pointCurve, refine: refine) }
            if let channels { c = Self.channelCurves(c, channels) }
            if saturation != 0 { c = Self.encode(Self.saturate(Self.decode(c), 1 + Float(saturation))) }
            if let color { c = Self.lookUp(c, color) }
            // Masks blend in linear light, as Core Image's blend with mask does in the working space.
            var linear: SIMD3<Float>?
            for mask in masks where mask.weights[i] > 0 {
                let before = linear ?? Self.decode(c)
                linear = before + (mask.local.apply(before) - before) * mask.weights[i]
            }
            if let linear { c = Self.encode(linear) }
            out[i * 4] = UInt8(max(0, min(255, (c.x * 255).rounded())))
            out[i * 4 + 1] = UInt8(max(0, min(255, (c.y * 255).rounded())))
            out[i * 4 + 2] = UInt8(max(0, min(255, (c.z * 255).rounded())))
        }
        return LookSample(pixels: out, width: width, height: height, area: area)
    }

    // MARK: Steps

    /// Linear-light steps of a mask: Temp and Tint (Core Image's white balance, as a 3 × 3 matrix
    /// on linear Rec. 2020), Exposure, then Saturation.
    struct LocalSteps {
        var matrix: [SIMD3<Double>]?
        var gain: Float
        var saturation: Float

        func apply(_ linear: SIMD3<Float>) -> SIMD3<Float> {
            var c = linear
            if let matrix {
                let wide = LookEmulator.toRec2020(SIMD3<Double>(c))
                let moved = matrix[0] * wide.x + matrix[1] * wide.y + matrix[2] * wide.z
                c = SIMD3<Float>(LookEmulator.fromRec2020(moved))
            }
            if gain != 1 { c *= gain }
            if saturation != 1 { c = LookEmulator.saturate(c, saturation) }
            return c
        }
    }

    private func localSteps(_ mask: DevelopSettings.Mask) -> LocalSteps {
        let temperature = mask.effective(.temperature), tint = mask.effective(.tint)
        let matrix = temperature != 0 || tint != 0 ? whiteBalance(temperature: temperature, tint: tint) : nil
        return LocalSteps(matrix: matrix, gain: Float(pow(2, mask.effective(.exposure))),
                          saturation: Float(1 + mask.effective(.saturation) / 100))
    }

    /// A mask's weight per pixel, measured on `settings` the first time its shape is used. A
    /// Luminance Range part depends on the photo's brightness under it, so a later change of the
    /// global sliders moves it a little; the final real render checks the result.
    private func weights(of mask: DevelopSettings.Mask, in settings: DevelopSettings) -> [Float]? {
        let shape = Shape(id: mask.id, components: mask.components, inverted: mask.inverted)
        if let known = weights[shape] { return known }
        guard let measured = weigh(settings, mask), measured.count == width * height else { return nil }
        weights[shape] = measured
        return measured
    }

    /// The columns of the matrix Core Image's temperature and tint filter applies for a mask's
    /// Temp and Tint (see `DevelopRenderer.applyLocal`), measured on three pure colors.
    private func whiteBalance(temperature: Double, tint: Double) -> [SIMD3<Double>]? {
        let key = "\(temperature),\(tint)"
        if let known = whiteBalances[key] { return known }
        let units: [Float] = [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1]
        let input = CIImage(bitmapData: units.withUnsafeBytes { Data($0) }, bytesPerRow: 48,
                            size: CGSize(width: 3, height: 1), format: .RGBAf,
                            colorSpace: DevelopRenderer.workingSpace)
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = input
        filter.neutral = CIVector(x: 6500 * pow(2, temperature / 100 * 0.8), y: tint)
        filter.targetNeutral = CIVector(x: 6500, y: 0)
        guard let output = filter.outputImage else { return nil }
        var result = [Float](repeating: 0, count: 12)
        result.withUnsafeMutableBytes { buffer in
            DevelopRenderer.shared.context.render(output, toBitmap: buffer.baseAddress!, rowBytes: 48,
                                                  bounds: CGRect(x: 0, y: 0, width: 3, height: 1), format: .RGBAf,
                                                  colorSpace: DevelopRenderer.workingSpace)
        }
        let columns = (0..<3).map { SIMD3<Double>(Double(result[$0 * 4]), Double(result[$0 * 4 + 1]), Double(result[$0 * 4 + 2])) }
        whiteBalances[key] = columns
        return columns
    }

    /// HSL / Point Color and Color Grading as one lookup table over sRGB-encoded colors, built
    /// from the renderer's own color code; nil when both are neutral.
    private func colorCube(_ settings: DevelopSettings) -> [SIMD3<Float>]? {
        let parameters = DevelopSettings.Parameter.allCases.filter { $0.panel == .hsl || $0.panel == .colorGrading }
        let key = parameters.map { settings[$0] }
        let mix = ColorMix(settings), grade = ColorGrade(settings)
        guard mix.hsl.isActive || mix.points.isActive || grade.isActive else { return nil }
        if key == cubeKey { return cube }
        let n = Self.cubeSize
        var values = [SIMD3<Float>](repeating: .zero, count: n * n * n)
        values.withUnsafeMutableBufferPointer { buffer in
            let output = buffer
            DispatchQueue.concurrentPerform(iterations: n) { b in
                for g in 0..<n {
                    for r in 0..<n {
                        let node: RGB = (Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                        let mixed = mix.apply(node)
                        let graded = grade.isActive ? grade.apply(mixed) : mixed
                        output[(b * n + g) * n + r] = SIMD3<Float>(Float(graded.0), Float(graded.1), Float(graded.2))
                    }
                }
            }
        }
        cubeKey = key
        cube = values
        return values
    }

    // MARK: Pixel math

    /// The renderer's tone curve kernel (`ToneCurve`): the curve moves the largest and smallest
    /// channel and the middle one keeps its place between them.
    /// `refine` below 1 is Refine Saturation: brightness only, the color scaled by what the
    /// curve does to its luma.
    static func hueCurve(_ c: SIMD3<Float>, _ lut: [Float], refine: Float = 1) -> SIMD3<Float> {
        let high = max(c.x, max(c.y, c.z)), low = min(c.x, min(c.y, c.z))
        let newHigh = curve(lut, high), newLow = curve(lut, low)
        var result = high - low < 1e-6 ? SIMD3(repeating: newHigh)
            : SIMD3(repeating: newLow) + (c - SIMD3(repeating: low)) * ((newHigh - newLow) / (high - low))
        if refine < 1 {
            let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let newY = curve(lut, y)
            let flat = y > 1e-4 ? c * (newY / y) : c + SIMD3(repeating: newY - y)
            result = flat + (result - flat) * refine
        }
        return result
    }

    static func channelCurves(_ c: SIMD3<Float>, _ lut: [Float]) -> SIMD3<Float> {
        let n = lut.count / 3
        func one(_ x: Float, _ channel: Int) -> Float {
            if x <= 0 { return lut[channel] + x }
            if x >= 1 { return lut[(n - 1) * 3 + channel] + (x - 1) }
            let position = x * Float(n - 1)
            let i = min(n - 2, Int(position)), t = position - Float(i)
            return lut[i * 3 + channel] + (lut[(i + 1) * 3 + channel] - lut[i * 3 + channel]) * t
        }
        return SIMD3(one(c.x, 0), one(c.y, 1), one(c.z, 2))
    }

    static func curve(_ lut: [Float], _ x: Float) -> Float {
        let n = lut.count
        if x <= 0 { return lut[0] + x }
        if x >= 1 { return lut[n - 1] + (x - 1) }
        let position = x * Float(n - 1)
        let i = min(n - 2, Int(position)), t = position - Float(i)
        return lut[i] + (lut[i + 1] - lut[i]) * t
    }

    /// Core Image's color controls Saturation, in the working space (linear Rec. 2020).
    static func saturate(_ linear: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        let wide = toRec2020(SIMD3<Double>(linear))
        let luma = 0.2125 * wide.x + 0.7154 * wide.y + 0.0721 * wide.z
        let moved = SIMD3<Double>(repeating: luma) + (wide - SIMD3<Double>(repeating: luma)) * Double(amount)
        return SIMD3<Float>(fromRec2020(moved))
    }

    /// Trilinear lookup in the color cube (inputs clamped to 0...1).
    static func lookUp(_ c: SIMD3<Float>, _ cube: [SIMD3<Float>]) -> SIMD3<Float> {
        let n = cubeSize
        let p = simd_clamp(c, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * Float(n - 1)
        let i0 = SIMD3<Int>(min(n - 2, Int(p.x)), min(n - 2, Int(p.y)), min(n - 2, Int(p.z)))
        let t = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { cube[(b * n + g) * n + r] }
        let c00 = at(i0.x, i0.y, i0.z) + (at(i0.x + 1, i0.y, i0.z) - at(i0.x, i0.y, i0.z)) * t.x
        let c10 = at(i0.x, i0.y + 1, i0.z) + (at(i0.x + 1, i0.y + 1, i0.z) - at(i0.x, i0.y + 1, i0.z)) * t.x
        let c01 = at(i0.x, i0.y, i0.z + 1) + (at(i0.x + 1, i0.y, i0.z + 1) - at(i0.x, i0.y, i0.z + 1)) * t.x
        let c11 = at(i0.x, i0.y + 1, i0.z + 1) + (at(i0.x + 1, i0.y + 1, i0.z + 1) - at(i0.x, i0.y + 1, i0.z + 1)) * t.x
        let c0 = c00 + (c10 - c00) * t.y, c1 = c01 + (c11 - c01) * t.y
        return c0 + (c1 - c0) * t.z
    }

    static func decode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(Float(Oklab.linear(Double(c.x))), Float(Oklab.linear(Double(c.y))), Float(Oklab.linear(Double(c.z))))
    }

    static func encode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(Float(Oklab.encoded(Double(c.x))), Float(Oklab.encoded(Double(c.y))), Float(Oklab.encoded(Double(c.z))))
    }

    /// Linear sRGB to linear Rec. 2020 and back (the renderer's working space).
    static func toRec2020(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.6274040 * c.x + 0.3292820 * c.y + 0.0433136 * c.z,
              0.0690970 * c.x + 0.9195400 * c.y + 0.0113612 * c.z,
              0.0163916 * c.x + 0.0880132 * c.y + 0.8955950 * c.z)
    }

    static func fromRec2020(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(1.6604910 * c.x - 0.5876411 * c.y - 0.0728499 * c.z,
              -0.1245505 * c.x + 1.1328999 * c.y - 0.0083494 * c.z,
              -0.0181508 * c.x - 0.1005789 * c.y + 1.1187297 * c.z)
    }
}
