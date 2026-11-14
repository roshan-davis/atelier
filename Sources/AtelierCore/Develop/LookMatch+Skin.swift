import CoreGraphics
import Foundation

/// How a skin fit ended, and what it learned (for a check on a real render).
struct SkinFit {
    enum Outcome: Sendable, Equatable {
        /// No step brought the skin closer; the settings are as they were.
        case unchanged
        /// The skin came to the reference (or was there already).
        case matched
        /// The skin came closer but stopped short, at the sliders' limits.
        case partial
    }

    var outcome: Outcome
    var solver: SkinSolver?
    /// How far the skin was from its target before the fit.
    var startError = 0.0
}

/// The joint skin fit: the skin masks' Temp, Tint and Saturation, solved together so every tone's
/// color comes to its target. The masks overlap (the base mask covers every tone, and the shadow
/// and highlight masks fade into the midtones), so fitting them one after another left the
/// midtones off once the ends were corrected. Each slider's effect on each tone is measured
/// (cheap on the stand-in), the moves are solved together by damped least squares, and a step is
/// kept only when it brings the tones closer.
struct SkinSolver {
    struct Tone {
        let pixels: [Int]
        let target: SIMD2<Double>
        /// Color relative to lightness (`LookSkin.relativeAB`), or plain mean a/b.
        let relative: Bool
    }

    static let parameters: [DevelopSettings.LocalParameter] = [.temperature, .tint, .saturation]
    /// Close enough, per tone, in Oklab a/b over lightness.
    static let tolerance = 0.003

    let masks: [String]
    let tones: [Tone]
    /// How far each slider may move from where it started.
    let limit: Double
    /// The sliders' values before the fit, by mask name.
    let start: [String: [Double]]
    /// Rows: each tone's a and b; columns: each mask's Temp, Tint and Saturation.
    var jacobian: [[Double]] = []

    var unknowns: Int { masks.count * Self.parameters.count }

    init(masks: [String], tones: [Tone], limit: Double, settings: DevelopSettings) {
        self.masks = masks
        self.tones = tones
        self.limit = limit
        var start: [String: [Double]] = [:]
        for name in masks {
            let mask = settings.masks.first { $0.name == name }
            start[name] = Self.parameters.map { mask?[$0] ?? 0 }
        }
        self.start = start
    }

    /// Each tone's color, a and b in turn.
    func colors(_ sample: LookSample) -> [Double]? {
        var out: [Double] = []
        out.reserveCapacity(tones.count * 2)
        for tone in tones {
            let color = tone.relative ? LookSkin.relativeAB(sample, tone.pixels) : LookSkin.meanAB(sample, tone.pixels)
            guard let color else { return nil }
            out += [color.x, color.y]
        }
        return out
    }

    /// The targets less the colors.
    func residual(_ colors: [Double]) -> [Double] {
        tones.enumerated().flatMap { k, tone in [tone.target.x - colors[2 * k], tone.target.y - colors[2 * k + 1]] }
    }

    static func norm(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    /// Close enough for every tone.
    var closeEnough: Double { Self.tolerance * Double(tones.count).squareRoot() }

    func value(_ settings: DevelopSettings, _ k: Int) -> Double {
        guard let index = settings.masks.firstIndex(where: { $0.name == masks[k / 3] }) else { return 0 }
        return settings.masks[index][Self.parameters[k % 3]]
    }

    /// `settings` with unknown `k` set to `value`, kept inside the limits.
    func setting(_ settings: DevelopSettings, _ k: Int, to value: Double) -> DevelopSettings {
        guard let index = settings.masks.firstIndex(where: { $0.name == masks[k / 3] }) else { return settings }
        let from = start[masks[k / 3]]?[k % 3] ?? 0
        var out = settings
        out.masks[index][Self.parameters[k % 3]] = min(min(100, from + limit), max(max(-100, from - limit), value)).rounded()
        return out
    }

    /// Measures how every slider moves every tone's color, around `settings` (whose colors are
    /// `colors`): one nudge per slider.
    mutating func measureJacobian(at settings: DevelopSettings, colors: [Double],
                                  measure: (DevelopSettings) -> LookSample?, isCancelled: () -> Bool) {
        var columns: [[Double]] = []
        for k in 0..<unknowns {
            let now = value(settings, k)
            let step = now > 85 ? -12.0 : 12.0
            var column = [Double](repeating: 0, count: colors.count)
            if !isCancelled(), let sample = measure(setting(settings, k, to: now + step)),
               let moved = self.colors(sample) {
                let actual = value(setting(settings, k, to: now + step), k) - now
                if abs(actual) > 0.5 { column = zip(moved, colors).map { ($0 - $1) / actual } }
            }
            columns.append(column)
        }
        jacobian = (0..<colors.count).map { row in columns.map { $0[row] } }
    }

    /// The slider moves that best bring `residual` to zero: damped least squares, so sliders
    /// that do nearly the same thing share the move instead of fighting.
    func step(_ residual: [Double]) -> [Double]? {
        let n = unknowns
        guard jacobian.count == residual.count, n > 0 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var g = [Double](repeating: 0, count: n)
        for (row, r) in zip(jacobian, residual) {
            for i in 0..<n {
                g[i] += row[i] * r
                for j in 0..<n { a[i][j] += row[i] * row[j] }
            }
        }
        let largest = (0..<n).map { a[$0][$0] }.max() ?? 0
        guard largest > 1e-14 else { return nil }
        for i in 0..<n { a[i][i] += 0.01 * largest }
        guard let x = Self.solve(a, g) else { return nil }
        return x.map { min(30, max(-30, $0)) }
    }

    /// `settings` moved by `delta` × `fraction`.
    func applying(_ delta: [Double], fraction: Double, to settings: DevelopSettings) -> DevelopSettings {
        var out = settings
        for k in 0..<min(unknowns, delta.count) where abs(delta[k] * fraction) >= 0.5 {
            out = setting(out, k, to: value(out, k) + delta[k] * fraction)
        }
        return out
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let n = vector.count
        var m = matrix, v = vector
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(m[row][column]) > abs(m[pivot][column]) { pivot = row }
            guard abs(m[pivot][column]) > 1e-18 else { return nil }
            if pivot != column {
                m.swapAt(pivot, column)
                v.swapAt(pivot, column)
            }
            for row in (column + 1)..<n {
                let factor = m[row][column] / m[column][column]
                guard factor != 0 else { continue }
                for k in column..<n { m[row][k] -= factor * m[column][k] }
                v[row] -= factor * v[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = sum / m[row][row]
        }
        return x
    }
}

extension LookMatcher {
    /// Match Skin Tone: fit ordinary mask color sliders (Temp, Tint, Saturation) on the rendered
    /// face pixels, tone by tone. The "Match Look: Skin" mask covers the skin and is the base
    /// color; "Match Look: Skin Shadows" and "Match Look: Skin Highlights" add a soft Luminance
    /// Range to the same skin. The photo's skin is split into darkest, middle and brightest
    /// thirds, which go to the reference's skin shadows, midtones and highlights; the three masks
    /// are solved together (`SkinSolver`). Color is scored in the Oklab color plane relative to
    /// lightness (`LookSkin.relativeAB`); lightness is left to the ordinary Tone fit, except that
    /// Protect Skin Tones (`holdsLightness`) also brings each tone's brightness back with the
    /// mask's Exposure.
    static func fitSkin(_ skin: LookSkin, to reference: LookSkin, in settings: inout DevelopSettings,
                        space: MaskSpace, measure: (DevelopSettings) -> LookSample?,
                        limit: Double = maxSkinShift, holdsLightness: Bool = false,
                        bodySkin: Bool = false, isCancelled: () -> Bool) -> SkinFit {
        // Vision's face box is tight: brows to chin, cheek to cheek, no forehead. The ellipse is
        // larger than the box and moved up over the forehead, with a short feather, so the
        // whole face gets the full effect (inside 70% of the radius) and it fades out past the
        // jaw, ears and hairline. A box-sized ellipse with a long feather reached only the
        // middle of each face.
        let radials = skin.faces.map { face -> DevelopSettings.MaskComponent in
            let center = CGPoint(x: face.midX * space.rect.width, y: (face.midY - 0.08 * face.height) * space.rect.height)
            let gradient = space.radial(center: center, width: face.width * space.rect.width * 0.62,
                                        height: face.height * space.rect.height * 0.75, feather: 30)
            return DevelopSettings.MaskComponent(.radial(gradient))
        }
        // With Select People: the Entire Face in one piece (and the body's skin with it, when the
        // parts model found it), so the base color has no holes and takes nothing by accident;
        // the tone masks blend in on top of it. Matching leaves the eyes' whites and irises out.
        var faces = radials
        if skin.usesPeople {
            faces = [DevelopSettings.MaskComponent(.people(LookSkin.maskSelection(bodySkin: bodySkin)))]
            if !holdsLightness {
                faces.append(DevelopSettings.MaskComponent(.people(LookSkin.eyesSelection), mode: .subtract))
            }
        }
        guard let start = measure(settings) else { return SkinFit(outcome: .unchanged) }

        // Color is matched relative to brightness (`LookSkin.relativeAB`): the face keeps its own
        // brightness, so the reference's absolute a/b would look more or less saturated on it.
        var masks: [(name: String, components: [DevelopSettings.MaskComponent])] = []
        var tones: [SkinSolver.Tone] = []
        var lightnessTargets: [Double?] = []
        let targets = reference.relativeToneColors
        if targets.count == 3 {
            // The photo's skin split into thirds by brightness after the global fit, measured
            // the way the masks' Luminance Range sees it.
            let split = LookSkin.toneSplit(start, skin.pixels)
            guard split.groups.count == 3, split.groups.allSatisfy({ !$0.isEmpty }) else {
                return SkinFit(outcome: .unchanged)
            }
            let (low, high) = (split.cuts.0 * 100, split.cuts.1 * 100)
            // Wide, soft ranges, so the shadow and highlight corrections fade into the base
            // color over the face instead of meeting it at a visible step (Rosh: "gradual and
            // seamless").
            let soft = 70.0
            func range(_ low: Double, _ high: Double) -> DevelopSettings.MaskComponent {
                DevelopSettings.MaskComponent(.luminance(DevelopSettings.LuminanceRange(low: low, high: high, smoothness: soft)),
                                              mode: .intersect)
            }
            masks = [(LookMatch.skinShadowsMaskName, faces + [range(0, low)]),
                     (LookMatch.skinMaskName, faces),
                     (LookMatch.skinHighlightsMaskName, faces + [range(high, 100)])]
            tones = (0..<3).map { SkinSolver.Tone(pixels: split.groups[$0], target: targets[$0], relative: true) }
            lightnessTargets = (0..<3).map {
                holdsLightness && reference.toneLightness.count == 3 ? reference.toneLightness[$0] : nil
            }
        } else {
            // Without tones: one mask, the skin's mean color to the reference's.
            let lightness = reference.toneLightness.isEmpty ? 0
                : reference.toneLightness.reduce(0, +) / Double(reference.toneLightness.count)
            let relative = lightness > 0.05
            let color = colorVector(hue: reference.hue, chroma: reference.chroma)
            masks = [(LookMatch.skinMaskName, faces)]
            tones = [SkinSolver.Tone(pixels: skin.pixels, target: relative ? color / lightness : color, relative: relative)]
            lightnessTargets = [nil]
        }

        var best = settings
        var added: [String] = []
        for mask in masks {
            if let index = best.masks.firstIndex(where: { $0.name == mask.name }) {
                // A repeat match keeps the mask (and its id) but takes the skin as found now.
                best.masks[index].components = mask.components
            } else {
                best.masks.append(.init(name: mask.name, components: mask.components))
                added.append(mask.name)
            }
        }
        var solver = SkinSolver(masks: masks.map(\.name), tones: tones, limit: limit, settings: best)
        guard let startColors = solver.colors(start) else { return SkinFit(outcome: .unchanged) }
        let startError = SkinSolver.norm(solver.residual(startColors))
        var improved = false

        // Protect Skin Tones: first each tone's brightness back with its mask's Exposure. Oklab
        // lightness is about the cube root of luminance, so a ratio r is about 3 log2(r) stops.
        for (k, target) in lightnessTargets.enumerated() {
            guard let target, target > 0.02, !isCancelled(),
                  let index = best.masks.firstIndex(where: { $0.name == masks[k].name }) else { continue }
            let pixels = tones[k].pixels
            func lightness(_ candidate: DevelopSettings) -> Double? {
                measure(candidate).flatMap { LookSkin.meanLightness($0, pixels) }
            }
            guard var now = lightness(best), now > 0.02 else { continue }
            for _ in 0..<2 where abs(now - target) >= 0.005 && !isCancelled() {
                var trial = best
                let exposure = trial.masks[index][.exposure] + 3 * log2(target / now)
                trial.masks[index][.exposure] = (min(1.5, max(-1.5, exposure)) * 100).rounded() / 100
                guard trial != best, let next = lightness(trial), abs(next - target) < abs(now - target) else { break }
                best = trial
                now = next
                improved = true
            }
        }

        guard let afterLightness = measure(best), var colors = solver.colors(afterLightness) else {
            return SkinFit(outcome: .unchanged)
        }
        var error = SkinSolver.norm(solver.residual(colors))
        if startError < solver.closeEnough && !improved {
            // Already there: nothing to add.
            return SkinFit(outcome: .matched)
        }
        for _ in 0..<skinRounds where error >= solver.closeEnough && !isCancelled() {
            solver.measureJacobian(at: best, colors: colors, measure: measure, isCancelled: isCancelled)
            guard let delta = solver.step(solver.residual(colors)) else { break }
            var stepped = false
            for fraction in [1.0, 0.5, 0.25] where !isCancelled() {
                let trial = solver.applying(delta, fraction: fraction, to: best)
                guard trial != best, let sample = measure(trial), let next = solver.colors(sample) else { continue }
                let nextError = SkinSolver.norm(solver.residual(next))
                guard nextError < error else { continue }
                best = trial
                colors = next
                error = nextError
                stepped = true
                improved = true
                break
            }
            if !stepped { break }
        }

        guard improved, !isCancelled() else { return SkinFit(outcome: .unchanged, solver: solver, startError: startError) }
        // A mask that moved nothing isn't worth adding.
        best.masks.removeAll { added.contains($0.name) && !$0.hasAdjustments }
        settings = best
        return SkinFit(outcome: outcome(error: error, start: startError, solver: solver), solver: solver,
                       startError: startError)
    }

    /// The skin fit runs on the stand-in (`LookEmulator`), which is close but not exact. One real
    /// render checks the skin; when it is off, one more step from the slopes the fit already
    /// measured, kept only if the real render comes closer (one or two more renders). Nil when
    /// there is nothing to check.
    static func settleSkin(_ settings: inout DevelopSettings, fit: SkinFit,
                           measure: (DevelopSettings) -> LookSample?) -> SkinFit.Outcome? {
        guard let solver = fit.solver, !solver.jacobian.isEmpty, let sample = measure(settings),
              let colors = solver.colors(sample) else { return nil }
        var error = SkinSolver.norm(solver.residual(colors))
        if error >= solver.closeEnough, let delta = solver.step(solver.residual(colors)) {
            for fraction in [1.0, 0.5] {
                let trial = solver.applying(delta, fraction: fraction, to: settings)
                guard trial != settings, let next = measure(trial).flatMap(solver.colors) else { continue }
                let nextError = SkinSolver.norm(solver.residual(next))
                guard nextError < error else { continue }
                settings = trial
                error = nextError
                break
            }
        }
        return outcome(error: error, start: fit.startError, solver: solver)
    }

    /// Matched when the tones are close or most of the way there; partial when the sliders'
    /// limits stopped the fit short.
    static func outcome(error: Double, start: Double, solver: SkinSolver) -> SkinFit.Outcome {
        error <= 2 * solver.closeEnough || error <= 0.35 * start ? .matched : .partial
    }

    /// Rounds of the joint skin fit, each with freshly measured slopes.
    static let skinRounds = 4

    /// The most Match Skin Tone moves each skin slider (Temp, Tint, Saturation) from where it was,
    /// for a photo reference: a reference whose skin sits under very different light shouldn't
    /// paint the face.
    static let maxSkinShift = 35.0
    /// The same for a built-in study, whose skin colors are drawn on purpose: Matrix's olive skin
    /// is about 55° of hue from an ordinary face and Fury Road's highlights need about 1.7 × the
    /// chroma, which ±35 couldn't reach (Rosh, Nov 14, 2026).
    static let studySkinShift = 60.0
    /// Protect Skin Tones' skin masks undo the look on the face, so they may use the sliders'
    /// whole range: at 35 they couldn't undo a strong Temp/Tint, and Protect then pulled the
    /// whole match back.
    static let protectSkinShift = 100.0

    private static func colorVector(hue: Double, chroma: Double) -> SIMD2<Double> {
        let angle = hue * .pi / 180
        return SIMD2(cos(angle), sin(angle)) * chroma
    }
}
