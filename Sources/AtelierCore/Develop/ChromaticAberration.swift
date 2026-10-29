import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// Lightroom's Lens Corrections color controls: Remove Chromatic Aberration (the red and blue
// channels lined up with green) and the manual Defringe sliders (purple and green fringes along
// high-contrast edges turned neutral). Both run in pipeline step 1, before the lens warp.

extension DevelopSettings {
    /// The purple and green Defringe colors.
    public enum FringeColor: String, CaseIterable, Hashable, Sendable {
        case purple, green

        public var title: String { rawValue.capitalized }

        public var amount: Parameter { self == .purple ? .lensDefringePurpleAmount : .lensDefringeGreenAmount }
        public var hueLow: Parameter { self == .purple ? .lensDefringePurpleHueLow : .lensDefringeGreenHueLow }
        public var hueHigh: Parameter { self == .purple ? .lensDefringePurpleHueHigh : .lensDefringeGreenHueHigh }

        /// The hue (degrees) at the left end of the Hue slider; the slider's 0...100 spans 120°.
        /// Purple runs from blue through violet to magenta, green from yellow through green to
        /// aqua, so blue skies and yellow-green foliage sit outside the default ranges.
        var hueStart: Double { self == .purple ? 225 : 60 }

        /// A Hue slider value (0...100) in degrees.
        public func degrees(_ value: Double) -> Double { hueStart + value * 1.2 }

        /// The Hue slider value (0...100) for a hue in degrees, or nil when it is off the slider.
        public func sliderValue(degrees: Double) -> Double? {
            var hue = degrees.truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            let value = (hue - hueStart) / 1.2
            return (0...100).contains(value) ? value : nil
        }
    }

    /// Lightroom keeps the two ends of a Hue range at least 10 apart.
    public static let minimumHueSpan = 10.0

    /// Sets a Defringe hue range, keeping it on the slider and at least `minimumHueSpan` wide.
    /// `moving` is the end being dragged, which gives way last; nil moves the whole range.
    public mutating func setHueRange(_ color: FringeColor, low: Double, high: Double, moving: Parameter? = nil) {
        let span = Self.minimumHueSpan
        var low = min(max(low, 0), 100), high = min(max(high, 0), 100)
        if high - low < span {
            if moving == color.hueHigh {
                low = max(0, high - span)
                high = low + span
            } else {
                high = min(100, low + span)
                low = high - span
            }
        }
        self[color.hueLow] = low
        self[color.hueHigh] = high
    }

    /// Whether Defringe changes anything.
    public var hasDefringe: Bool { FringeColor.allCases.contains { self[$0.amount] > 0 } }
}

extension DevelopSettings.Parameter {
    /// One of the Defringe sliders.
    public var isDefringe: Bool { rawValue.hasPrefix("lensDefringe") }
}

// MARK: Lateral chromatic aberration

/// Lateral chromatic aberration: the lens draws red and blue a little larger or smaller than
/// green, so edges toward the corners get red-cyan or blue-yellow fringes. Remove Chromatic
/// Aberration measures how much from the photo itself and scales those channels back.
public struct LateralCA: Equatable, Sendable {
    /// Each channel is sampled at center + offset × (1 + scale): positive for a channel the lens
    /// draws larger than green.
    public var red: Double
    public var blue: Double

    public init(red: Double, blue: Double) {
        self.red = red
        self.blue = blue
    }

    public static let none = LateralCA(red: 0, blue: 0)

    public var isNone: Bool { abs(red) < 1e-6 && abs(blue) < 1e-6 }

    /// Scales searched, either way: 0.3% is about 10 pixels in the corner of a 24 MP photo,
    /// more than any lens we expect.
    static let searchLimit = 0.003
    static let searchStep = 0.0001

    /// Measures the aberration from display-like (gamma-encoded) channels, `width × height`
    /// each, first row at the top. For every strong edge away from the center, the red and
    /// blue radial gradients are compared with green's at each candidate scale; the scale that
    /// lines them up best wins, refined between steps. Nil channels or too few edges give none.
    public static func estimate(red: [Float], green: [Float], blue: [Float], width: Int, height: Int) -> LateralCA {
        let count = width * height
        guard width > 16, height > 16, red.count >= count, green.count >= count, blue.count >= count else { return .none }
        let cx = Double(width) / 2, cy = Double(height) / 2
        let halfDiagonal = (cx * cx + cy * cy).squareRoot()

        /// The derivative along the line from the center, by central differences.
        func radial(_ channel: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: count)
            for y in 1..<(height - 1) {
                let dy = Double(y) + 0.5 - cy
                for x in 1..<(width - 1) {
                    let dx = Double(x) + 0.5 - cx
                    let r = max(1e-6, (dx * dx + dy * dy).squareRoot())
                    let i = y * width + x
                    let gx = (channel[i + 1] - channel[i - 1]) / 2
                    let gy = (channel[i + width] - channel[i - width]) / 2
                    out[i] = gx * Float(dx / r) + gy * Float(dy / r)
                }
            }
            return out
        }
        let gRadial = radial(green), rRadial = radial(red), bRadial = radial(blue)

        // Strong, unclipped edges away from the center, where the aberration shows.
        var candidates: [Int] = []
        for y in 2..<(height - 2) {
            let dy = Double(y) + 0.5 - cy
            for x in 2..<(width - 2) {
                let dx = Double(x) + 0.5 - cx
                guard (dx * dx + dy * dy).squareRoot() > 0.3 * halfDiagonal else { continue }
                let i = y * width + x
                guard abs(gRadial[i]) > 0.03 else { continue }
                guard max(red[i], green[i], blue[i]) < 0.97 else { continue }
                candidates.append(i)
            }
        }
        guard candidates.count >= 300 else { return .none }
        if candidates.count > 40_000 {
            candidates.sort { abs(gRadial[$0]) > abs(gRadial[$1]) }
            candidates.removeLast(candidates.count - 40_000)
        }

        func bilinear(_ plane: [Float], _ x: Double, _ y: Double) -> Double {
            // Pixel i's center is at i + 0.5.
            let fx = x - 0.5, fy = y - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return 0 }
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            let i = y0 * width + x0
            let top = plane[i] * (1 - tx) + plane[i + 1] * tx
            let bottom = plane[i + width] * (1 - tx) + plane[i + width + 1] * tx
            return Double(top * (1 - ty) + bottom * ty)
        }

        var greenEnergy = 0.0
        for i in candidates { greenEnergy += Double(gRadial[i] * gRadial[i]) }

        func correlation(_ plane: [Float], _ scale: Double) -> Double {
            var dot = 0.0, energy = 0.0
            for i in candidates {
                let x = Double(i % width) + 0.5, y = Double(i / width) + 0.5
                let v = bilinear(plane, cx + (x - cx) * (1 + scale), cy + (y - cy) * (1 + scale))
                dot += v * Double(gRadial[i])
                energy += v * v
            }
            return dot / max(1e-12, (energy * greenEnergy).squareRoot())
        }

        func best(_ plane: [Float]) -> Double {
            let steps = Int((searchLimit / searchStep).rounded())
            let scores = (-steps...steps).map { correlation(plane, Double($0) * searchStep) }
            guard let top = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[top] > 0.3 else { return 0 }
            var scale = Double(top - steps) * searchStep
            if top > 0, top < scores.count - 1 {
                // The peak of the parabola through the best step and its neighbors.
                let a = scores[top - 1], b = scores[top], c = scores[top + 1]
                let denominator = a - 2 * b + c
                if denominator < 0 { scale += searchStep * 0.5 * (a - c) / denominator }
            }
            return scale
        }
        return LateralCA(red: best(rRadial), blue: best(bRadial))
    }

    /// Measures a decoded photo (working space, extent at the origin), rendered at most
    /// `sampleSize` pixels on the long edge.
    static func measure(_ image: CIImage, context: CIContext) -> LateralCA {
        let extent = image.extent
        let long = max(extent.width, extent.height)
        guard long >= 16 else { return .none }
        let factor = min(1, sampleSize / long)
        var small = image
        if factor < 1 {
            small = image.applyingFilter("CILanczosScaleTransform",
                                         parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
        }
        let bounds = small.extent.integral.intersection(CGRect(x: 0, y: 0, width: extent.width * factor,
                                                               height: extent.height * factor).integral)
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 16, height > 16 else { return .none }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(small, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: bounds,
                           format: .RGBAf, colorSpace: DevelopRenderer.workingSpace)
        }
        var red = [Float](repeating: 0, count: width * height)
        var green = red, blue = red
        for i in 0..<(width * height) {
            red[i] = powf(max(0, pixels[i * 4]), 1 / 2.2)
            green[i] = powf(max(0, pixels[i * 4 + 1]), 1 / 2.2)
            blue[i] = powf(max(0, pixels[i * 4 + 2]), 1 / 2.2)
        }
        return estimate(red: red, green: green, blue: blue, width: width, height: height)
    }

    /// Long edge of the render measured.
    static let sampleSize = 2000.0

    /// Below this long edge (thumbnails) the aberration is under a pixel, so a render neither
    /// measures nor corrects it unless the photo was already measured.
    static let minimumSize = 1000.0

    /// Scales red and blue about the center of `image` (extent at the origin).
    func apply(to image: CIImage) -> CIImage {
        guard !isNone, let kernel = Self.kernel else { return image }
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let reach = max(abs(red), abs(blue)) * (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2 + 2
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) },
                            arguments: [image.clampedToExtent(),
                                        CIVector(x: center.x, y: center.y, z: CGFloat(red), w: CGFloat(blue))])?
            .cropped(to: extent) ?? image
    }

    /// Whether the kernel built, for tests.
    static var kernelAvailable: Bool { kernel != nil }

    /// Built from Metal at run time, like the lens warp. Without it the photo is left as it is.
    private static let kernel: CIKernel? = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            // lens: the center, then the red and blue scales.
            [[stitchable]] float4 atelierLateralCA(coreimage::sampler image, float4 lens, coreimage::destination dest) {
                float2 p = dest.coord();
                float2 v = p - lens.xy;
                float4 g = image.sample(image.transform(p));
                float r = image.sample(image.transform(lens.xy + v * (1.0 + lens.z))).r;
                float b = image.sample(image.transform(lens.xy + v * (1.0 + lens.w))).b;
                return float4(r, g.g, b, g.a);
            }
            """
        return RuntimeKernels.build(source)?["atelierLateralCA"]
    }()
}

final class LateralCABox: NSObject {
    let value: LateralCA
    init(_ value: LateralCA) { self.value = value }
}

extension DevelopRenderer {
    /// The lateral chromatic aberration measured for a file (with or without the RAW engine's
    /// profile corrections), if it has been measured this session.
    func cachedLateralCA(for url: URL, profileCorrections: Bool) -> LateralCA? {
        lateralCAs.object(forKey: Self.lateralCAKey(url, profileCorrections))?.value
    }

    /// Measures `image`, the file's decoded photo, and keeps the result for the session, so
    /// every render of the photo (proxy, full size, export) uses the same correction.
    func lateralCA(for url: URL, profileCorrections: Bool, image: CIImage) -> LateralCA {
        let key = Self.lateralCAKey(url, profileCorrections)
        if let cached = lateralCAs.object(forKey: key) { return cached.value }
        let value = LateralCA.measure(image, context: context)
        lateralCAs.setObject(LateralCABox(value), forKey: key)
        return value
    }

    private static func lateralCAKey(_ url: URL, _ profileCorrections: Bool) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(profileCorrections)" as NSString
    }
}

// MARK: Defringe

/// Lightroom's manual Defringe: purple and green fringes along high-contrast edges (mostly
/// from out-of-focus highlights at wide apertures) lose their color, keeping their brightness.
///
/// A pixel is treated as fringe when its hue is inside the color's Hue range, it is saturated
/// enough to be a color at all, and a strong light-dark edge lies within reach. Amount (0...20)
/// sets both the reach (about 1 to 11 full-size pixels) and how readily an edge counts, so
/// higher values remove more. Hue and saturation are measured on display-like values (sRGB
/// primaries, gamma 2.2) so the ranges match the colors on the sliders.
public enum Defringe {
    /// What the kernel draws: the photo, or one of the Option-drag views.
    public enum View: Hashable, Sendable {
        case photo
        /// White, with the pixels Amount turns neutral shown in their color.
        case amount(DevelopSettings.FringeColor)
        /// Black outside the Hue range, the photo inside it.
        case hue(DevelopSettings.FringeColor)

        var code: Double {
            switch self {
            case .photo: return 0
            case .amount(let color): return color == .purple ? 1 : 2
            case .hue(let color): return color == .purple ? 3 : 4
            }
        }
    }

    /// The edge search radius in full-size pixels for an Amount of 0...20.
    static func reach(amount: Double) -> Double { 1 + amount / 2 }

    /// `scale` is the render's size relative to the full photo, so the proxy and an export match.
    static func apply(_ image: CIImage, settings: DevelopSettings, scale: Double, view: View = .photo) -> CIImage {
        guard settings.hasDefringe || view != .photo,
              let kernels = kernels, let lumaKernel = kernels["atelierFringeLuma"],
              let kernel = kernels["atelierDefringe"] else { return image }
        let extent = image.extent
        guard let luma = lumaKernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [image]) else {
            return image
        }
        func range(_ color: DevelopSettings.FringeColor) -> (CIImage, CIImage) {
            let radius = Float(max(1, (reach(amount: settings[color.amount]) * scale).rounded()))
            let maximum = CIFilter.morphologyMaximum()
            maximum.inputImage = luma.clampedToExtent()
            maximum.radius = radius
            let minimum = CIFilter.morphologyMinimum()
            minimum.inputImage = luma.clampedToExtent()
            minimum.radius = radius
            return (maximum.outputImage?.cropped(to: extent) ?? luma, minimum.outputImage?.cropped(to: extent) ?? luma)
        }
        func parameters(_ color: DevelopSettings.FringeColor) -> CIVector {
            CIVector(x: color.degrees(settings[color.hueLow]), y: color.degrees(settings[color.hueHigh]),
                     z: settings[color.amount] / 20, w: 0)
        }
        let purple = range(.purple), green = range(.green)
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                            arguments: [image, purple.0, purple.1, green.0, green.1,
                                        parameters(.purple), parameters(.green), view.code])?
            .cropped(to: extent) ?? image
    }

    // MARK: Colors

    /// Working-space (linear Rec. 2020) RGB to display-like values: sRGB primaries, clipped,
    /// gamma 2.2. The kernel does the same.
    public static func display(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let r = 1.6605 * c.x - 0.5876 * c.y - 0.0728 * c.z
        let g = -0.1246 * c.x + 1.1329 * c.y - 0.0083 * c.z
        let b = -0.0182 * c.x - 0.1006 * c.y + 1.1187 * c.z
        func encode(_ v: Double) -> Double { pow(min(max(v, 0), 1), 1 / 2.2) }
        return SIMD3(encode(r), encode(g), encode(b))
    }

    /// HSV hue in degrees and saturation 0...1 of display-like values.
    public static func hueSaturation(_ s: SIMD3<Double>) -> (hue: Double, saturation: Double) {
        let maximum = max(s.x, s.y, s.z), minimum = min(s.x, s.y, s.z)
        let chroma = maximum - minimum
        guard chroma > 1e-5 else { return (0, 0) }
        var hue: Double
        if maximum == s.x {
            hue = (s.y - s.z) / chroma
            if hue < 0 { hue += 6 }
        } else if maximum == s.y {
            hue = (s.z - s.x) / chroma + 2
        } else {
            hue = (s.x - s.y) / chroma + 4
        }
        return (hue * 60, chroma / max(maximum, 1e-5))
    }

    /// What the Fringe Color Selector sets for a click.
    public struct Pick: Equatable, Sendable {
        public var color: DevelopSettings.FringeColor
        public var hueLow: Double
        public var hueHigh: Double
        public var amount: Double
    }

    /// Colors below this saturation are not a fringe.
    static let minimumPickSaturation = 0.08

    /// The Hue range and Amount for a click on a fringe: `samples` are the working-space
    /// colors around the click. The most saturated color that falls on the purple or green
    /// Hue slider wins; its range is centered on it, 20 wide, and Amount goes to 5 if it was
    /// off. Nil when nothing there is a purple or green fringe.
    public static func pick(_ samples: [SIMD3<Double>], settings: DevelopSettings) -> Pick? {
        var best: (color: DevelopSettings.FringeColor, value: Double, saturation: Double)?
        for sample in samples {
            let (hue, saturation) = hueSaturation(display(sample))
            guard saturation >= minimumPickSaturation, saturation > (best?.saturation ?? 0) else { continue }
            for color in DevelopSettings.FringeColor.allCases {
                if let value = color.sliderValue(degrees: hue) { best = (color, value, saturation) }
            }
        }
        guard let best else { return nil }
        let half = 10.0
        let low = min(max(best.value - half, 0), 100 - 2 * half)
        let current = settings[best.color.amount]
        return Pick(color: best.color, hueLow: low.rounded(), hueHigh: (low + 2 * half).rounded(),
                    amount: current > 0 ? current : 5)
    }

    // MARK: Kernels

    /// Whether the kernels built, for tests.
    static var kernelsAvailable: Bool { kernels != nil }

    /// Built from Metal at run time, like the lens warp. Without them Defringe is left off.
    private static let kernels: [String: CIKernel]? = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            // Linear Rec. 2020 to sRGB primaries, clipped, gamma 2.2 (Defringe.display).
            static float3 atelierFringeDisplay(float3 c) {
                float3 s = float3(dot(c, float3(1.6605, -0.5876, -0.0728)),
                                  dot(c, float3(-0.1246, 1.1329, -0.0083)),
                                  dot(c, float3(-0.0182, -0.1006, 1.1187)));
                return pow(clamp(s, 0.0, 1.0), float3(1.0 / 2.2));
            }

            // HSV hue in degrees and saturation (Defringe.hueSaturation).
            static float2 atelierFringeHueSat(float3 s) {
                float mx = max(s.r, max(s.g, s.b));
                float mn = min(s.r, min(s.g, s.b));
                float c = mx - mn;
                if (c < 1e-5) { return float2(0.0, 0.0); }
                float h;
                if (mx == s.r) {
                    h = (s.g - s.b) / c;
                    if (h < 0.0) { h += 6.0; }
                } else if (mx == s.g) {
                    h = (s.b - s.r) / c + 2.0;
                } else {
                    h = (s.r - s.g) / c + 4.0;
                }
                return float2(h * 60.0, c / max(mx, 1e-5));
            }

            // Inside the hue range, with soft 6° shoulders.
            static float atelierFringeHue(float h, float4 range) {
                return smoothstep(range.x - 6.0, range.x, h) * (1.0 - smoothstep(range.y, range.y + 6.0, h));
            }

            // How much of a fringe to remove: hue, saturation, a strong edge within reach, and
            // Amount (range.z, 0...1).
            static float atelierFringeRemove(float hue, float sat, float contrast, float4 range) {
                if (range.z <= 0.0) { return 0.0; }
                float t = 0.28 - 0.14 * range.z;
                float edge = smoothstep(t, t + 0.12, contrast);
                return atelierFringeHue(hue, range) * smoothstep(0.04, 0.12, sat) * edge * min(1.0, 0.45 + 3.0 * range.z);
            }

            // Display-like luminance, for the edge contrast.
            [[stitchable]] float4 atelierFringeLuma(coreimage::sampler image, coreimage::destination dest) {
                float3 c = image.sample(image.transform(dest.coord())).rgb;
                float y = pow(max(dot(c, float3(0.2627, 0.6780, 0.0593)), 0.0), 1.0 / 2.2);
                return float4(y, y, y, 1.0);
            }

            // view: 0 the photo, 1 and 2 the purple and green Amount views, 3 and 4 the Hue views.
            [[stitchable]] float4 atelierDefringe(coreimage::sampler image,
                                                  coreimage::sampler purpleMax, coreimage::sampler purpleMin,
                                                  coreimage::sampler greenMax, coreimage::sampler greenMin,
                                                  float4 purple, float4 green, float view,
                                                  coreimage::destination dest) {
                float2 p = dest.coord();
                float4 c = image.sample(image.transform(p));
                float2 hs = atelierFringeHueSat(atelierFringeDisplay(c.rgb));
                float purpleContrast = purpleMax.sample(purpleMax.transform(p)).r - purpleMin.sample(purpleMin.transform(p)).r;
                float greenContrast = greenMax.sample(greenMax.transform(p)).r - greenMin.sample(greenMin.transform(p)).r;
                float rp = atelierFringeRemove(hs.x, hs.y, purpleContrast, purple);
                float rg = atelierFringeRemove(hs.x, hs.y, greenContrast, green);
                if (view > 0.5 && view < 1.5) { return float4(mix(float3(1.0), c.rgb, rp), 1.0); }
                if (view > 1.5 && view < 2.5) { return float4(mix(float3(1.0), c.rgb, rg), 1.0); }
                float sat = smoothstep(0.04, 0.12, hs.y);
                if (view > 2.5 && view < 3.5) { return float4(c.rgb * atelierFringeHue(hs.x, purple) * sat, 1.0); }
                if (view > 3.5) { return float4(c.rgb * atelierFringeHue(hs.x, green) * sat, 1.0); }
                float remove = max(rp, rg);
                float y = dot(c.rgb, float3(0.2627, 0.6780, 0.0593));
                return float4(mix(c.rgb, float3(y), remove), c.a);
            }
            """
        guard let built = RuntimeKernels.build(source), built.count == 2 else { return nil }
        return built
    }()
}
