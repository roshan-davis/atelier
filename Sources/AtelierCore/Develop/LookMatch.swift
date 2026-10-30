import CoreGraphics
import Foundation
import ImageIO

/// Match Look to a Reference: works out ordinary Develop settings (White Balance, Exposure, the
/// RGB Tone Curve, Saturation and Color Grading) that give a photo the look of a reference image.
/// Each step renders the photo through the real pipeline and corrects itself against that render,
/// so the result reflects what the sliders actually do. See the PRD's "Match Look to a Reference".
public struct LookMatch: Sendable, Equatable {
    /// The photo's settings before the match.
    public var base: DevelopSettings
    /// The settings at full strength.
    public var matched: DevelopSettings
    /// The photo's as-shot white balance, for blending a temperature that was left as shot.
    public var asShotTemperature: Double

    public init(base: DevelopSettings, matched: DevelopSettings, asShotTemperature: Double) {
        self.base = base
        self.matched = matched
        self.asShotTemperature = asShotTemperature
    }

    /// Plain sliders the match may move; temperature, the RGB curve and the grading wheels are
    /// blended separately.
    static let linearParameters: [DevelopSettings.Parameter] = [.tint, .exposure, .saturation]
        + DevelopSettings.Parameter.allCases.filter { $0.hslBand != nil }
    static let gradeRegions: [DevelopSettings.GradeRegion] = [.shadows, .highlights]

    /// The settings at `strength` (0 to 1) between `base` and `matched`.
    public func settings(strength: Double) -> DevelopSettings {
        applied(to: base, strength: strength)
    }

    /// `other` with the matched values copied over it at `strength`, as when syncing the match to
    /// more photos (Same settings). The rest of `other` is kept.
    public func applied(to other: DevelopSettings, strength: Double) -> DevelopSettings {
        let s = min(1, max(0, strength))
        var out = other
        guard s > 0 else { return out }
        let full = s == 1
        if matched.temperature != base.temperature {
            let from = 1e6 / (base.temperature ?? asShotTemperature)
            let to = 1e6 / (matched.temperature ?? asShotTemperature)
            out.temperature = full ? matched.temperature : 1e6 / (from + (to - from) * s)
        }
        for parameter in Self.linearParameters where matched[parameter] != base[parameter] {
            out[parameter] = full ? matched[parameter] : base[parameter] + (matched[parameter] - base[parameter]) * s
        }
        let fromCurve = base.points(for: .rgb), toCurve = matched.points(for: .rgb)
        if fromCurve != toCurve {
            out.setPoints(full ? toCurve : toCurve.map { point in
                let y0 = DevelopRenderer.pointCurveValue(fromCurve, at: point.x)
                return DevelopSettings.CurvePoint(x: point.x, y: y0 + (point.y - y0) * s)
            }, for: .rgb)
        }
        for region in Self.gradeRegions
        where matched[region.hue] != base[region.hue] || matched[region.saturation] != base[region.saturation] {
            let from = GradeVector(hue: base[region.hue], saturation: base[region.saturation])
            let to = GradeVector(hue: matched[region.hue], saturation: matched[region.saturation])
            guard !full else {
                out[region.hue] = matched[region.hue]
                out[region.saturation] = matched[region.saturation]
                continue
            }
            let mixed = from + (to - from) * s
            if mixed.saturation > 0.05 { out[region.hue] = (mixed.hue * 10).rounded() / 10 }
            out[region.saturation] = (mixed.saturation * 10).rounded() / 10
        }
        return out
    }
}

/// What the match changes, from the dialog's checkboxes.
public struct LookMatchOptions: Sendable, Equatable {
    /// Temp and Tint.
    public var whiteBalance = true
    /// Exposure and the RGB Tone Curve.
    public var tone = true
    /// Saturation, the HSL bands and the Shadows and Highlights grading wheels.
    public var color = true

    public init(whiteBalance: Bool = true, tone: Bool = true, color: Bool = true) {
        self.whiteBalance = whiteBalance
        self.tone = tone
        self.color = color
    }

    public var isEmpty: Bool { !whiteBalance && !tone && !color }
}

/// An image's colors in Oklab, measured on a small copy. `area` (0 to 1 from the top left)
/// marks the part that should match: it carries three quarters of the weight.
public struct LookSample: Sendable {
    /// Long edge the images are measured at.
    public static let size = 384
    static let areaShare = 0.75

    var lightness: [Float] = []
    var a: [Float] = []
    var b: [Float] = []
    /// sRGB-encoded luma, as the tone curve sees it.
    var luma: [Float] = []
    var weight: [Double] = []

    public init?(image: CGImage, area: CGRect? = nil) {
        let factor = min(1, Double(Self.size) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: DevelopRenderer.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(pixels: data, width: width, height: height, area: area)
    }

    /// Packed RGBA8 sRGB pixels, rows from the top.
    public init(pixels: [UInt8], width: Int, height: Int, area: CGRect? = nil) {
        let count = min(pixels.count / 4, width * height)
        lightness.reserveCapacity(count)
        a.reserveCapacity(count)
        b.reserveCapacity(count)
        luma.reserveCapacity(count)
        var inside = [Bool](repeating: false, count: count)
        let linear = Self.linearTable
        for i in 0..<count {
            let r8 = Int(pixels[i * 4]), g8 = Int(pixels[i * 4 + 1]), b8 = Int(pixels[i * 4 + 2])
            let lab = Self.oklab(linear[r8], linear[g8], linear[b8])
            lightness.append(Float(lab.0))
            a.append(Float(lab.1))
            b.append(Float(lab.2))
            luma.append(Float((0.2126 * Double(r8) + 0.7152 * Double(g8) + 0.0722 * Double(b8)) / 255))
            if let area {
                let x = (Double(i % width) + 0.5) / Double(width), y = (Double(i / width) + 0.5) / Double(height)
                inside[i] = area.contains(CGPoint(x: x, y: y))
            }
        }
        let insideCount = inside.filter { $0 }.count
        if area != nil, insideCount > 0, insideCount < count {
            let wIn = Self.areaShare / Double(insideCount), wOut = (1 - Self.areaShare) / Double(count - insideCount)
            weight = inside.map { $0 ? wIn : wOut }
        } else {
            weight = [Double](repeating: 1 / Double(max(1, count)), count: count)
        }
    }

    var count: Int { lightness.count }

    // MARK: Statistics

    /// Weighted mean of a and b over the pixels `include` picks, with an extra weight per pixel.
    func meanAB(_ extra: (Int) -> Double) -> SIMD2<Double>? {
        var sum = SIMD2<Double>(0, 0), total = 0.0
        for i in 0..<count {
            let w = weight[i] * extra(i)
            guard w > 0 else { continue }
            sum += SIMD2(Double(a[i]), Double(b[i])) * w
            total += w
        }
        return total > 1e-9 ? sum / total : nil
    }

    /// The average color of the midtones, which white balance matches.
    var midtoneAB: SIMD2<Double> {
        meanAB { i in self.lightness[i] > 0.3 && self.lightness[i] < 0.88 ? 1 : 0 } ?? meanAB { _ in 1 } ?? .zero
    }

    /// The average color of the shadows or highlights, weighted the way the grading wheels are.
    func regionAB(_ region: DevelopSettings.GradeRegion) -> SIMD2<Double> {
        meanAB { i in
            let y = Double(self.luma[i])
            switch region {
            case .shadows: return pow(max(0, 1 - y / 0.5), 2)
            case .highlights: return pow(max(0, (y - 0.5) / 0.5), 2)
            default: return 1
            }
        } ?? .zero
    }

    /// Weighted median of Oklab lightness.
    var medianLightness: Double {
        let order = (0..<count).sorted { lightness[$0] < lightness[$1] }
        let total = weight.reduce(0, +)
        var running = 0.0
        for i in order {
            running += weight[i]
            if running >= total / 2 { return Double(lightness[i]) }
        }
        return 0.5
    }

    /// Weighted mean chroma, leaving out near-black and near-white pixels.
    var meanChroma: Double {
        var sum = 0.0, total = 0.0
        for i in 0..<count where lightness[i] > 0.15 && lightness[i] < 0.95 {
            sum += Double((a[i] * a[i] + b[i] * b[i]).squareRoot()) * weight[i]
            total += weight[i]
        }
        return total > 0 ? sum / total : 0
    }

    func lumaHistogram(bins: Int = 256) -> [Double] {
        var counts = [Double](repeating: 0, count: bins)
        for i in 0..<count {
            counts[min(bins - 1, max(0, Int(luma[i] * Float(bins))))] += weight[i]
        }
        return counts
    }

    /// Mean Oklab distance between two samples of the same size, pixel by pixel (for tests).
    public func distance(to other: LookSample) -> Double {
        guard count == other.count, count > 0 else { return .infinity }
        var sum = 0.0
        for i in 0..<count {
            let dl = Double(lightness[i] - other.lightness[i]), da = Double(a[i] - other.a[i]),
                db = Double(b[i] - other.b[i])
            sum += (dl * dl + da * da + db * db).squareRoot()
        }
        return sum / Double(count)
    }

    /// One HSL band's share of the image and the average color of the pixels it covers: Oklab
    /// hue in degrees, chroma and lightness, as the HSL panel sees them.
    struct BandStats {
        var share = 0.0
        var hue = 0.0
        var chroma = 0.0
        var lightness = 0.0
    }

    /// Per HSL band, weighted the way the HSL panel weights a pixel's hue between two band centers.
    /// Grays and near-black or near-white pixels are left out, as the panel barely moves them.
    func bandStats() -> [BandStats] {
        let bands = DevelopSettings.ColorBand.allCases.count
        var weightSum = [Double](repeating: 0, count: bands), cosSum = weightSum, sinSum = weightSum,
            chromaSum = weightSum, lightSum = weightSum
        let total = weight.reduce(0, +)
        for i in 0..<count {
            let l = Double(lightness[i]), da = Double(a[i]), db = Double(b[i])
            let c = (da * da + db * db).squareRoot()
            guard c > 0.03, l > 0.2, l < 0.95 else { continue }
            var h = atan2(db, da) * 180 / .pi
            if h < 0 { h += 360 }
            for (band, share) in HSLAdjustment.weights(for: h).enumerated() where share > 0 {
                let w = weight[i] * share
                weightSum[band] += w
                cosSum[band] += cos(h * .pi / 180) * w
                sinSum[band] += sin(h * .pi / 180) * w
                chromaSum[band] += c * w
                lightSum[band] += l * w
            }
        }
        return (0..<bands).map { band in
            let w = weightSum[band]
            guard w > 0, total > 0 else { return BandStats() }
            var degrees = atan2(sinSum[band], cosSum[band]) * 180 / .pi
            if degrees < 0 { degrees += 360 }
            return BandStats(share: w / total, hue: degrees, chroma: chromaSum[band] / w, lightness: lightSum[band] / w)
        }
    }

    // MARK: Sliced Wasserstein distance

    /// Fixed directions in Oklab, spread over the sphere, along which colors are compared.
    static let directions: [SIMD3<Double>] = (0..<24).map { i in
        let y = 1 - (Double(i) + 0.5) / 12, radius = (1 - y * y).squareRoot()
        let angle = Double(i) * 2.399963
        return SIMD3(y, cos(angle) * radius, sin(angle) * radius)
    }
    static let quantileCount = 32

    /// The image's colors seen along each direction, as weighted quantiles.
    func projectedQuantiles() -> [[Double]] {
        let stride = max(1, count / 6000)
        let picked = Swift.stride(from: 0, to: count, by: stride).map { $0 }
        let total = picked.reduce(0.0) { $0 + weight[$1] }
        return Self.directions.map { d in
            let values = picked.map { i in
                (Double(lightness[i]) * d.x + Double(a[i]) * d.y + Double(b[i]) * d.z, weight[i])
            }.sorted { $0.0 < $1.0 }
            var quantiles = [Double](), running = 0.0, k = 0
            for j in 0..<Self.quantileCount {
                let level = (Double(j) + 0.5) / Double(Self.quantileCount) * total
                while k < values.count - 1, running + values[k].1 < level {
                    running += values[k].1
                    k += 1
                }
                quantiles.append(values.isEmpty ? 0 : values[k].0)
            }
            return quantiles
        }
    }

    /// How far apart two images' color distributions are, whatever their content's layout: the
    /// sliced Wasserstein distance (Rabin, Peyré, Delon and Bernot, 2011) over `directions`.
    static func slicedDistance(_ p: [[Double]], _ q: [[Double]]) -> Double {
        guard p.count == q.count, !p.isEmpty else { return .infinity }
        var sum = 0.0
        for (x, y) in zip(p, q) {
            for (u, v) in zip(x, y) { sum += abs(u - v) }
        }
        return sum / Double(p.count * quantileCount)
    }

    // MARK: Oklab

    static let linearTable: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear sRGB to Oklab (Björn Ottosson, 2020).
    static func oklab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}

/// A grading wheel's hue and saturation as a point on the wheel, so two can be added and blended.
struct GradeVector {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(hue: Double, saturation: Double) {
        x = cos(hue * .pi / 180) * saturation
        y = sin(hue * .pi / 180) * saturation
    }

    var saturation: Double { (x * x + y * y).squareRoot() }
    var hue: Double {
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    static func + (l: GradeVector, r: GradeVector) -> GradeVector { GradeVector(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: GradeVector, r: GradeVector) -> GradeVector { GradeVector(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: GradeVector, r: Double) -> GradeVector { GradeVector(x: l.x * r, y: l.y * r) }
}

public enum LookMatcher {
    /// Limits, so an odd reference can't wreck the photo.
    static let maxMiredShift = 150.0
    static let maxTintShift = 60.0
    static let maxExposureShift = 2.0
    static let saturationRange = -60.0...60.0
    static let maxGradeSaturation = 50.0

    /// Fits `settings` on `session`'s photo to `reference`. `photoArea` (0 to 1 from the top left
    /// of the cropped photo) marks the part to match, like the reference's area. Returns nil when
    /// the photo can't be rendered.
    public static func match(session: DevelopSession, settings base: DevelopSettings, reference: LookSample,
                             options: LookMatchOptions = LookMatchOptions(), photoArea: CGRect? = nil,
                             isCancelled: () -> Bool = { false }) -> LookMatch? {
        func measure(_ settings: DevelopSettings) -> LookSample? {
            session.renderSRGB(settings).flatMap { LookSample(image: $0, area: photoArea) }
        }
        guard measure(base) != nil else { return nil }
        var current = base
        let asShot = session.asShotTemperature
        if options.whiteBalance, !isCancelled() {
            fitWhiteBalance(&current, asShot: asShot, reference: reference, measure: measure)
        }
        if options.tone, !isCancelled() {
            fitExposure(&current, reference: reference, measure: measure)
            fitCurve(&current, reference: reference, measure: measure)
        }
        if options.color, !isCancelled() {
            fitSaturation(&current, reference: reference, measure: measure)
            fitHSL(&current, reference: reference, measure: measure)
            fitGrade(&current, reference: reference, measure: measure)
        }
        if !isCancelled() {
            refine(&current, asShot: asShot, options: options, reference: reference, measure: measure,
                   isCancelled: isCancelled)
        }
        guard !isCancelled() else { return nil }
        return LookMatch(base: base, matched: current, asShotTemperature: asShot)
    }

    /// Temp and Tint: Newton steps on the midtones' average color, with the slopes measured by
    /// rendering a small nudge of each slider.
    static func fitWhiteBalance(_ settings: inout DevelopSettings, asShot: Double, reference: LookSample,
                                measure: (DevelopSettings) -> LookSample?) {
        let target = reference.midtoneAB
        let startMired = 1e6 / (settings.temperature ?? asShot), startTint = settings.tint
        var mired = startMired, tint = startTint
        func with(_ m: Double, _ t: Double) -> DevelopSettings {
            var s = settings
            s.temperature = 1e6 / m
            s.tint = t
            return s
        }
        for _ in 0..<3 {
            guard let photo = measure(with(mired, tint)) else { return }
            let error = target - photo.midtoneAB
            if (error * error).sum() < 0.0015 * 0.0015 { break }
            guard let warmer = measure(with(mired + 15, tint)), let greener = measure(with(mired, tint + 8)) else { return }
            let j1 = (warmer.midtoneAB - photo.midtoneAB) / 15, j2 = (greener.midtoneAB - photo.midtoneAB) / 8
            let det = j1.x * j2.y - j2.x * j1.y
            guard abs(det) > 1e-12 else { break }
            let dm = (error.x * j2.y - j2.x * error.y) / det
            let dt = (j1.x * error.y - error.x * j1.y) / det
            mired = min(startMired + maxMiredShift, max(startMired - maxMiredShift, mired + min(60, max(-60, dm))))
            mired = min(1e6 / 2000, max(1e6 / 50000, mired))
            tint = min(startTint + maxTintShift, max(startTint - maxTintShift, tint + min(30, max(-30, dt))))
        }
        if abs(mired - startMired) > 0.5 || settings.temperature != nil { settings.temperature = (1e6 / mired).rounded() }
        settings.tint = tint.rounded()
    }

    /// Exposure: moves the median brightness to the reference's. Oklab lightness is close to the
    /// cube root of luminance, so a ratio r in lightness is about 3 log2(r) stops.
    static func fitExposure(_ settings: inout DevelopSettings, reference: LookSample,
                            measure: (DevelopSettings) -> LookSample?) {
        let target = reference.medianLightness
        let start = settings.exposure
        for _ in 0..<2 {
            guard let photo = measure(settings) else { return }
            let median = photo.medianLightness
            guard median > 0.02, target > 0.02 else { return }
            let stops = 3 * log2(target / median)
            if abs(stops) < 0.03 { break }
            settings.exposure = min(start + maxExposureShift, max(start - maxExposureShift, settings.exposure + stops))
        }
        settings.exposure = (settings.exposure * 100).rounded() / 100
    }

    /// The x positions of a fitted curve's points; few, so the curve stays easy to edit.
    static let curveXs = [0, 0.25, 0.5, 0.75, 1.0]

    /// The RGB Tone Curve: histogram matching on brightness, put on top of the photo's own curve.
    static func fitCurve(_ settings: inout DevelopSettings, reference: LookSample,
                         measure: (DevelopSettings) -> LookSample?) {
        guard let photo = measure(settings),
              let curve = CameraMatch.matchingCurve(source: photo.lumaHistogram(), target: reference.lumaHistogram(),
                                                    maxShift: CameraMatch.maxShift, blackCeiling: 0.15,
                                                    whiteFloor: 0.85) else { return }
        let fitted = CameraMatch(curve: curve, saturation: 1)
        let master = settings.points(for: .rgb)
        var xs = curveXs
        for point in master where !xs.contains(where: { abs($0 - point.x) < 0.06 }) { xs.append(point.x) }
        let points = xs.sorted().map { x in
            let y = fitted.value(at: DevelopRenderer.pointCurveValue(master, at: x))
            return DevelopSettings.CurvePoint(x: x, y: (y * 1000).rounded() / 1000)
        }
        settings.setPoints(points, for: .rgb)
    }

    /// Saturation: the reference's mean chroma against the photo's. The slider scales chroma.
    static func fitSaturation(_ settings: inout DevelopSettings, reference: LookSample,
                              measure: (DevelopSettings) -> LookSample?) {
        let target = reference.meanChroma
        guard target > 0.005 else { return }
        for _ in 0..<2 {
            guard let photo = measure(settings) else { return }
            let chroma = photo.meanChroma
            guard chroma > 0.005 else { return }
            let ratio = target / chroma
            if abs(ratio - 1) < 0.02 { break }
            let factor = (1 + settings.saturation / 100) * ratio
            settings.saturation = min(saturationRange.upperBound, max(saturationRange.lowerBound, (factor - 1) * 100)).rounded()
        }
    }

    /// HSL: per band, moves hue, saturation and luminance toward the reference's average for that
    /// band. Bands covering less than about 1% of either image are left alone. Two damped rounds, each
    /// measured on a fresh render, since neighboring bands overlap.
    static func fitHSL(_ settings: inout DevelopSettings, reference: LookSample,
                       measure: (DevelopSettings) -> LookSample?) {
        let target = reference.bandStats()
        for _ in 0..<2 {
            guard let photo = measure(settings) else { return }
            let current = photo.bandStats()
            for (i, band) in DevelopSettings.ColorBand.allCases.enumerated() {
                let t = target[i], p = current[i]
                guard t.share > 0.008, p.share > 0.008 else { continue }
                let hue = DevelopSettings.Parameter.hsl(.hue, band)
                let saturation = DevelopSettings.Parameter.hsl(.saturation, band)
                let luminance = DevelopSettings.Parameter.hsl(.luminance, band)
                var dh = (t.hue - p.hue).truncatingRemainder(dividingBy: 360)
                if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
                // A band's Hue slider at 100 turns its colors most of the way to the next band.
                let reach = HSLAdjustment.hueReach(i, positive: dh > 0)
                if abs(dh) > 2 {
                    settings[hue] = min(maxHSLHue, max(-maxHSLHue, settings[hue] + dh / reach * 100 * damping)).rounded()
                }
                if p.chroma > 0.03 {
                    let ratio = 1 + (t.chroma / p.chroma - 1) * damping
                    let value = ((1 + settings[saturation] / 100) * ratio - 1) * 100
                    settings[saturation] = min(maxHSLSaturation, max(-maxHSLSaturation, value)).rounded()
                }
                // Luminance moves a color by about amount × 0.5 × its strength × its room to move.
                let dl = t.lightness - p.lightness
                let room = 0.5 * HSLAdjustment.strength(p.chroma) * (dl > 0 ? 1 - p.lightness : p.lightness)
                if abs(dl) > 0.01, room > 0.01 {
                    let value = settings[luminance] + dl / room * 100 * damping
                    settings[luminance] = min(maxHSLLuminance, max(-maxHSLLuminance, value)).rounded()
                }
            }
        }
    }

    /// The last step: small moves of the main sliders, kept only when they bring the photo's whole
    /// color distribution closer to the reference's (sliced Wasserstein distance), so the sliders
    /// fitted one at a time settle together.
    static func refine(_ settings: inout DevelopSettings, asShot: Double, options: LookMatchOptions,
                       reference: LookSample, measure: (DevelopSettings) -> LookSample?, isCancelled: () -> Bool) {
        let target = reference.projectedQuantiles()
        func score(_ candidate: DevelopSettings) -> Double? {
            measure(candidate).map { LookSample.slicedDistance($0.projectedQuantiles(), target) }
        }
        guard var best = score(settings) else { return }
        var knobs: [(DevelopSettings, Double) -> DevelopSettings] = []
        if options.whiteBalance {
            knobs.append { s, step in
                var out = s
                let mired = 1e6 / (s.temperature ?? asShot) + 8 * step
                out.temperature = (1e6 / min(1e6 / 2000, max(1e6 / 50000, mired))).rounded()
                return out
            }
            knobs.append { s, step in
                var out = s
                out.tint = (s.tint + 4 * step).rounded()
                return out
            }
        }
        if options.tone {
            knobs.append { s, step in
                var out = s
                out.exposure = ((s.exposure + 0.1 * step) * 100).rounded() / 100
                return out
            }
        }
        if options.color {
            knobs.append { s, step in
                var out = s
                out.saturation = min(saturationRange.upperBound, max(saturationRange.lowerBound, s.saturation + 5 * step)).rounded()
                return out
            }
        }
        for scale in [1.0, 0.5] {
            for knob in knobs {
                guard !isCancelled() else { return }
                for sign in [1.0, -1.0] {
                    let candidate = knob(settings, sign * scale)
                    guard candidate != settings, let value = score(candidate) else { continue }
                    if value < best - 1e-5 {
                        best = value
                        settings = candidate
                        break
                    }
                }
            }
        }
    }

    static let damping = 0.8
    static let maxHSLHue = 50.0
    static let maxHSLSaturation = 60.0
    static let maxHSLLuminance = 50.0

    /// Color Grading's Shadows and Highlights wheels take the color difference left between dark
    /// and bright tones once the midtones match (split toning).
    static func fitGrade(_ settings: inout DevelopSettings, reference: LookSample,
                         measure: (DevelopSettings) -> LookSample?) {
        // Color Grading switched off stays off.
        guard settings.isOn(.colorGrading), let photo = measure(settings) else { return }
        let midShift = reference.midtoneAB - photo.midtoneAB
        let probe = 20.0
        var needs: [(DevelopSettings.GradeRegion, SIMD2<Double>, Double)] = []
        var probed = settings
        for region in LookMatch.gradeRegions {
            let need = reference.regionAB(region) - photo.regionAB(region) - midShift
            guard (need * need).sum() > 0.003 * 0.003 else { continue }
            let hue = gradeHue(towards: need)
            let old = GradeVector(hue: settings[region.hue], saturation: settings[region.saturation])
            let tried = old + GradeVector(hue: hue, saturation: probe)
            probed[region.hue] = tried.hue
            probed[region.saturation] = tried.saturation
            needs.append((region, need, hue))
        }
        guard !needs.isEmpty, let after = measure(probed) else { return }
        for (region, need, hue) in needs {
            let length = (need * need).sum().squareRoot()
            let moved = after.regionAB(region) - photo.regionAB(region) - (after.midtoneAB - photo.midtoneAB)
            let achieved = (moved * need).sum() / length
            guard achieved > 1e-4 else { continue }
            let amount = min(maxGradeSaturation, probe * length / achieved)
            let old = GradeVector(hue: settings[region.hue], saturation: settings[region.saturation])
            let result = old + GradeVector(hue: hue, saturation: amount)
            settings[region.hue] = result.hue.rounded()
            settings[region.saturation] = min(100, result.saturation).rounded()
        }
    }

    /// Oklab a/b direction of each grading wheel hue (whole degrees), as Color Grading tints.
    static let gradeDirections: [Double] = ColorGrade.directions.map { atan2($0.y, $0.x) }

    /// The grading wheel hue that pushes colors most nearly along `direction` in Oklab a/b.
    static func gradeHue(towards direction: SIMD2<Double>) -> Double {
        let angle = atan2(direction.y, direction.x)
        var best = 0, bestGap = Double.infinity
        for (hue, value) in gradeDirections.enumerated() {
            var gap = abs(value - angle)
            if gap > .pi { gap = 2 * .pi - gap }
            if gap < bestGap {
                best = hue
                bestGap = gap
            }
        }
        return Double(best)
    }
}

// MARK: Loading a reference

public enum LookReference {
    /// A file's image at about `maxPixelSize` on the long edge, upright: the image itself, or a
    /// RAW's embedded preview.
    public static func image(at url: URL, maxPixelSize: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }
}
