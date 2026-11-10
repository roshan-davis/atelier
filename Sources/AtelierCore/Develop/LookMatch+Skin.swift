import CoreGraphics
import Foundation

extension LookMatcher {
    /// Fit ordinary mask color sliders on the rendered face pixels. Score hue and chroma
    /// together in the Oklab color plane, with lightness left to the ordinary Tone fit.
    static func fitSkin(_ skin: LookSkin, to reference: LookSkin, in settings: inout DevelopSettings,
                        space: MaskSpace, measure: (DevelopSettings) -> LookSample?,
                        isCancelled: () -> Bool) -> Bool {
        let target = colorVector(hue: reference.hue, chroma: reference.chroma)
        func color(_ candidate: DevelopSettings) -> SIMD2<Double>? {
            guard !isCancelled(), let sample = measure(candidate),
                  let measured = LookSkin.hueAndChroma(sample, skin.pixels) else { return nil }
            return colorVector(hue: measured.hue, chroma: measured.chroma)
        }
        guard var measured = color(settings) else { return false }
        let tolerance = 0.002
        var error = target - measured
        if (error * error).sum() < tolerance * tolerance { return true }

        let existing = settings.masks.firstIndex { $0.name == LookMatch.skinMaskName }
        let index = existing ?? settings.masks.count
        var best = settings
        if skin.usesPeople {
            // Everyone's face skin, editable as a Select People part in Masking (tick Body Skin
            // there to carry the change to neck and hands). Body skin is found by color alone, so
            // warm clothes can join it; the match leaves it out.
            let part = DevelopSettings.MaskComponent(.people(LookSkin.matchSelection))
            if let existing {
                // An earlier match's face ellipses become the people part.
                if !best.masks[existing].components.contains(where: { $0.kind == .people }) {
                    best.masks[existing].components = [part]
                }
            } else {
                best.masks.append(.init(name: LookMatch.skinMaskName, components: [part]))
            }
        } else if existing == nil {
            let components = skin.faces.map { face in
                let center = CGPoint(x: face.midX * space.rect.width, y: (face.midY + 0.04 * face.height) * space.rect.height)
                let gradient = space.radial(center: center, width: face.width * space.rect.width * 0.48,
                                            height: face.height * space.rect.height * 0.48, feather: 45)
                return DevelopSettings.MaskComponent(.radial(gradient))
            }
            best.masks.append(.init(name: LookMatch.skinMaskName, components: components))
        }

        var improved = false
        // Keep the skin sliders near where they started: a reference whose skin sits under very
        // different light shouldn't paint the face.
        let start = DevelopSettings.LocalParameter.allCases.reduce(into: [DevelopSettings.LocalParameter: Double]()) {
            $0[$1] = best.masks[index][$1]
        }
        func limited(_ parameter: DevelopSettings.LocalParameter, _ value: Double) -> Double {
            let from = start[parameter] ?? 0
            return min(from + maxSkinShift, max(from - maxSkinShift, value))
        }
        // Measure the response to each slider on this image. Solve for Temp and Tint
        // together because their color directions overlap, then let Saturation refine it.
        for _ in 0..<3 {
            func slope(_ parameter: DevelopSettings.LocalParameter) -> SIMD2<Double> {
                var trial = best
                let value = trial.masks[index][parameter]
                let step = value > 85 ? -12.0 : 12.0
                trial.masks[index][parameter] = value + step
                guard let result = color(trial) else { return .zero }
                return (result - measured) / step
            }

            func tryStep(_ changes: [(DevelopSettings.LocalParameter, Double)]) {
                for fraction in [1.0, 0.5, 0.25] {
                    var trial = best
                    for (parameter, delta) in changes {
                        let value = trial.masks[index][parameter]
                        trial.masks[index][parameter] = limited(parameter, (value + min(30, max(-30, delta)) * fraction).rounded())
                    }
                    guard trial != best, let result = color(trial) else { continue }
                    let next = target - result
                    guard (next * next).sum() < (error * error).sum() else { continue }
                    best = trial
                    measured = result
                    error = next
                    improved = true
                    break
                }
            }

            let temp = slope(.temperature), tint = slope(.tint)
            let determinant = temp.x * tint.y - tint.x * temp.y
            if abs(determinant) > 1e-10 {
                tryStep([(.temperature, (error.x * tint.y - error.y * tint.x) / determinant),
                         (.tint, (temp.x * error.y - temp.y * error.x) / determinant)])
            }
            let saturation = slope(.saturation)
            let response = (saturation * saturation).sum()
            if response > 1e-10 {
                tryStep([(.saturation, (error * saturation).sum() / response)])
            }
            if (error * error).sum() < tolerance * tolerance || isCancelled() { break }
        }

        if improved { settings = best }
        return improved
    }

    /// The most Match Skin Tone moves each skin slider (Temp, Tint, Saturation) from where it was.
    static let maxSkinShift = 35.0

    private static func colorVector(hue: Double, chroma: Double) -> SIMD2<Double> {
        let angle = hue * .pi / 180
        return SIMD2(cos(angle), sin(angle)) * chroma
    }
}
