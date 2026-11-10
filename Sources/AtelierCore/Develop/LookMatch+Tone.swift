import Foundation

// Tone and tonal color for Match Look: the curve from brightness percentiles (so blacks stay
// black unless the reference is really faded), white balance from the near-neutral pixels, and
// the three Color Grading wheels from the color of the neutrals in each tonal range.

extension LookSample {
    /// Weighted percentiles (0 to 1) of sRGB-encoded luma, in the order asked.
    func lumaPercentiles(_ shares: [Double]) -> [Double] {
        guard count > 0 else { return [] }
        let order = (0..<count).sorted { luma[$0] < luma[$1] }
        let total = weight.reduce(0, +)
        guard total > 0 else { return [] }
        var running = 0.0, next = 0
        let wanted = shares.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: shares.count)
        for i in order {
            running += weight[i]
            while next < wanted.count, running >= wanted[next].element * total {
                result[wanted[next].offset] = Double(luma[i])
                next += 1
            }
            if next == wanted.count { break }
        }
        while next < wanted.count {
            result[wanted[next].offset] = Double(luma[order.last!])
            next += 1
        }
        return result
    }

    /// The color cast of the scene's neutrals: the mean a/b of the least colorful 30% of the
    /// midtones (Oklab L 0.3 to 0.85). A green field or a blue wall is not an illuminant, so
    /// colorful pixels are left out. Falls back to all midtones when too few pixels qualify.
    var neutralAB: SIMD2<Double> {
        var chromas: [(Float, Double)] = []
        chromas.reserveCapacity(count)
        var total = 0.0
        for i in 0..<count where lightness[i] > 0.3 && lightness[i] < 0.85 && weight[i] > 0 {
            chromas.append(((a[i] * a[i] + b[i] * b[i]).squareRoot(), weight[i]))
            total += weight[i]
        }
        guard total > 0.02 else { return midtoneAB }
        chromas.sort { $0.0 < $1.0 }
        var running = 0.0
        var limit = chromas.last?.0 ?? 0
        for (chroma, w) in chromas {
            running += w
            if running >= total * 0.3 {
                limit = chroma
                break
            }
        }
        return meanAB { i in
            guard self.lightness[i] > 0.3, self.lightness[i] < 0.85 else { return 0 }
            return (self.a[i] * self.a[i] + self.b[i] * self.b[i]).squareRoot() <= limit ? 1 : 0
        } ?? midtoneAB
    }

    /// The color of the shadows, midtones or highlights: the mean a/b of each pixel weighted by
    /// how much that Color Grading wheel reaches it (the renderer's own weights for this Blending
    /// and Balance) and by how neutral it is, so object colors count less than the tint over them.
    func toneCast(_ region: DevelopSettings.GradeRegion, blending: Double, balance: Double) -> SIMD2<Double> {
        let index = ColorGrade.index(of: region)
        return meanAB { i in
            let reach = ColorGrade.weights(luma: Double(self.luma[i]), blending: blending, balance: balance)[index]
            let chroma = Double((self.a[i] * self.a[i] + self.b[i] * self.b[i]).squareRoot())
            return reach / (1 + (chroma / 0.05) * (chroma / 0.05))
        } ?? .zero
    }
}

extension LookMatcher {
    /// Where the fitted curve's points sit; seven, so a fade and an S-curve can both be shown.
    static let curveXs = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
    /// The brightness percentiles the curve matches. Matching a few percentiles, not the whole
    /// histogram, follows the reference's contrast without copying how much sky it has.
    static let curvePercentiles = [0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99]

    /// The rising curve, sampled at 256 inputs, that takes the photo's brightness percentiles to
    /// the reference's. Black stays black and white stays white unless the reference itself is
    /// faded: its darkest 1% lifted above 6% while a quarter of it is still darker than 45% (so
    /// there are dark tones to judge by). White comes down at most to 92%, and only when the
    /// reference's brightest 1% stays under 90% in a bright image. Nil when either sample is empty.
    static func toneCurve(photo: LookSample, reference: LookSample) -> [Float]? {
        let p = photo.lumaPercentiles(curvePercentiles), r = reference.lumaPercentiles(curvePercentiles)
        guard p.count == curvePercentiles.count, r.count == p.count else { return nil }
        let last = p.count - 1
        let fadedBlack = r[0] > 0.06 && r[2] < 0.45
        let fadedWhite = r[last] < 0.9 && r[last - 2] > 0.55
        let black = fadedBlack ? min(0.15, max(0, r[0] - p[0])) : 0
        let white = fadedWhite ? max(0.92, 1 - max(0, p[last] - r[last])) : 1
        var knots: [(Double, Double)] = [(0, black)]
        for k in 0...last {
            // A bright reference with no darks says nothing about blacks; likewise for whites.
            if k <= 1, !fadedBlack, r[k] > 0.06 + p[k] { continue }
            if k >= last - 1, !fadedWhite, r[k] < p[k] - 0.07 { continue }
            let x = p[k]
            guard x > knots.last!.0 + 0.02, x < 0.98 else { continue }
            let y = min(x + CameraMatch.maxShift, max(x - CameraMatch.maxShift, r[k]))
            knots.append((x, max(knots.last!.1, y)))
        }
        knots.append((1, max(knots.last!.1, white)))

        let bins = 256
        var raw = [Double](repeating: 0, count: bins)
        var segment = 0
        for i in 0..<bins {
            let x = Double(i) / Double(bins - 1)
            while segment < knots.count - 2, x > knots[segment + 1].0 { segment += 1 }
            let (x0, y0) = knots[segment], (x1, y1) = knots[segment + 1]
            raw[i] = x1 > x0 ? y0 + (y1 - y0) * (x - x0) / (x1 - x0) : y1
        }
        // Smooth the corners at the knots, keep black and white where they were put, keep rising.
        var curve = [Float](repeating: 0, count: bins)
        var previous = black
        for i in 0..<bins {
            let radius = min(10, i, bins - 1 - i)
            let lower = i - radius, upper = i + radius
            var y = raw[lower...upper].reduce(0, +) / Double(upper - lower + 1)
            if i == 0 { y = black }
            if i == bins - 1 { y = white }
            y = max(previous, y)
            curve[i] = Float(y)
            previous = y
        }
        return curve
    }

    /// The RGB Tone Curve: the reference's brightness percentiles, put on top of the photo's own curve.
    static func fitCurve(_ settings: inout DevelopSettings, reference: LookSample,
                         measure: (DevelopSettings) -> LookSample?) {
        guard let photo = measure(settings), let curve = toneCurve(photo: photo, reference: reference) else { return }
        let fitted = CameraMatch(curve: curve, saturation: 1)
        let master = settings.points(for: .rgb)
        var xs = curveXs
        for point in master where !xs.contains(where: { abs($0 - point.x) < 0.04 }) { xs.append(point.x) }
        let points = xs.sorted().map { x in
            let y = fitted.value(at: DevelopRenderer.pointCurveValue(master, at: x))
            return DevelopSettings.CurvePoint(x: x, y: (y * 1000).rounded() / 1000)
        }
        settings.setPoints(points, for: .rgb)
    }

    /// Color Grading's Shadows, Midtones and Highlights wheels take the color of light and shade:
    /// the cast of the neutrals in each tonal range (`toneCast`), matched to the reference's.
    /// Each wheel is nudged once to measure how much it moves every range (they overlap), the
    /// three moves are solved together, and the step is kept only if it brings the casts closer.
    /// Two rounds.
    static func fitGrade(_ settings: inout DevelopSettings, reference: LookSample,
                         measure: (DevelopSettings) -> LookSample?) {
        // Color Grading switched off stays off.
        guard settings.isOn(.colorGrading) else { return }
        let regions = LookMatch.gradeRegions
        let blending = settings[.gradeBlending] / 100, balance = settings[.gradeBalance] / 100
        func casts(_ sample: LookSample) -> [SIMD2<Double>] {
            regions.map { sample.toneCast($0, blending: blending, balance: balance) }
        }
        let target = casts(reference)
        func error(_ c: [SIMD2<Double>]) -> Double {
            zip(target, c).reduce(0) { sum, pair in
                let d = pair.0 - pair.1
                return sum + (d * d).sum()
            }
        }
        guard let photo = measure(settings) else { return }
        var current = casts(photo)
        var currentError = error(current)
        let probe = 20.0
        for _ in 0..<2 {
            let needs = zip(target, current).map { $0 - $1 }
            guard currentError > 3 * 0.003 * 0.003 else { break }
            // gain[i][j]: how far range i's cast moves along wheel j's push, per unit of wheel j.
            var gain = [[Double]](repeating: [Double](repeating: 0, count: regions.count), count: regions.count)
            for (j, wheel) in regions.enumerated() {
                let need = needs[j]
                let hue = (need * need).sum() > 1e-8 ? gradeHue(towards: need) : 0
                var nudged = settings
                let old = GradeVector(hue: settings[wheel.hue], saturation: settings[wheel.saturation])
                let tried = old + GradeVector(hue: hue, saturation: probe)
                nudged[wheel.hue] = tried.hue.rounded()
                nudged[wheel.saturation] = min(100, tried.saturation).rounded()
                guard let after = measure(nudged) else { return }
                let moved = zip(casts(after), current).map { $0 - $1 }
                let push = moved[j]
                let length = (push * push).sum().squareRoot()
                guard length > 1e-6 else { continue }
                let direction = push / length
                for i in regions.indices { gain[i][j] = (moved[i] * direction).sum() / probe }
            }
            // Solve gain × move = need for the a and b parts of the moves.
            guard let solveX = solve3(gain, needs.map(\.x)), let solveY = solve3(gain, needs.map(\.y)) else { break }
            var trial = settings
            for (j, wheel) in regions.enumerated() {
                let move = SIMD2(solveX[j], solveY[j])
                let amount = (move * move).sum().squareRoot()
                guard amount > 0.5 else { continue }
                let old = GradeVector(hue: settings[wheel.hue], saturation: settings[wheel.saturation])
                var result = old + GradeVector(hue: gradeHue(towards: move), saturation: min(30, amount))
                if result.saturation > maxGradeSaturation { result = result * (maxGradeSaturation / result.saturation) }
                trial[wheel.hue] = result.hue.rounded()
                trial[wheel.saturation] = result.saturation.rounded()
            }
            guard trial != settings, let after = measure(trial) else { break }
            let next = casts(after)
            let nextError = error(next)
            guard nextError < currentError else { break }
            settings = trial
            current = next
            currentError = nextError
        }
    }

    /// Solves a 3 × 3 system (or smaller), falling back to each range's own wheel alone when the
    /// wheels' effects can't be told apart.
    private static func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        let n = v.count
        guard n == 3, m.count == 3 else {
            return (0..<n).map { abs(m[$0][$0]) > 1e-6 ? v[$0] / m[$0][$0] : 0 }
        }
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        let scale = m.joined().reduce(0) { max($0, abs($1)) }
        guard scale > 1e-9 else { return nil }
        guard abs(d) > 1e-3 * scale * scale * scale else {
            return (0..<n).map { abs(m[$0][$0]) > 1e-6 ? v[$0] / m[$0][$0] : 0 }
        }
        return (0..<3).map { column in
            var replaced = m
            for row in 0..<3 { replaced[row][column] = v[row] }
            return det(replaced) / d
        }
    }
}
