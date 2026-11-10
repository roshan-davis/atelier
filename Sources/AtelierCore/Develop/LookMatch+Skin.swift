import CoreGraphics
import Foundation

extension LookMatcher {
    /// Match Skin Tone: fit ordinary mask color sliders (Temp, Tint, Saturation) on the rendered
    /// face pixels, tone by tone. The "Match Look: Skin" mask covers the faces and takes the
    /// photo's skin midtones to the reference's; "Match Look: Skin Shadows" and "Match Look: Skin
    /// Highlights" add a Luminance Range to the same faces and take the darkest and brightest
    /// thirds of the skin to the reference's skin shadows and highlights. Color is scored in the
    /// Oklab color plane; lightness is left to the ordinary Tone fit. False when no tone came closer.
    static func fitSkin(_ skin: LookSkin, to reference: LookSkin, in settings: inout DevelopSettings,
                        space: MaskSpace, measure: (DevelopSettings) -> LookSample?,
                        isCancelled: () -> Bool) -> Bool {
        // Vision's face box is tight: brows to chin, cheek to cheek, no forehead. The ellipse is
        // larger than the box and moved up over the forehead, with a short feather, so the
        // whole face gets the full effect (inside 70% of the radius) and it fades out past the
        // jaw, ears and hairline. A box-sized ellipse with a long feather reached only the
        // middle of each face.
        let faces = skin.faces.map { face -> DevelopSettings.MaskComponent in
            let center = CGPoint(x: face.midX * space.rect.width, y: (face.midY - 0.08 * face.height) * space.rect.height)
            let gradient = space.radial(center: center, width: face.width * space.rect.width * 0.62,
                                        height: face.height * space.rect.height * 0.75, feather: 30)
            return DevelopSettings.MaskComponent(.radial(gradient))
        }
        guard reference.toneColors.count == 3, let start = measure(settings) else {
            // Without tones: one mask, the skin's mean color to the reference's.
            return fitMaskColor(LookMatch.skinMaskName, components: faces,
                                target: colorVector(hue: reference.hue, chroma: reference.chroma),
                                in: &settings, measure: measure, isCancelled: isCancelled) { sample in
                LookSkin.hueAndChroma(sample, skin.pixels).map { colorVector(hue: $0.hue, chroma: $0.chroma) }
            }
        }
        // The photo's skin split into thirds by brightness after the global fit, which is what
        // the masks' Luminance Range sees.
        let split = LookSkin.toneSplit(start, skin.pixels)
        guard split.groups.count == 3 else { return false }
        let (low, high) = (split.cuts.0 * 100, split.cuts.1 * 100)
        let soft = 30.0
        func range(_ low: Double, _ high: Double) -> DevelopSettings.MaskComponent {
            DevelopSettings.MaskComponent(.luminance(DevelopSettings.LuminanceRange(low: low, high: high, smoothness: soft)),
                                          mode: .intersect)
        }
        // Indexed by tone: shadows, midtones, highlights. Midtones go first: the whole-face mask
        // moves every tone, and the other two correct the ends.
        let masks: [(String, [DevelopSettings.MaskComponent])] = [
            (LookMatch.skinShadowsMaskName, faces + [range(0, low)]),
            (LookMatch.skinMaskName, faces),
            (LookMatch.skinHighlightsMaskName, faces + [range(high, 100)])
        ]
        var matched = false
        for tone in [1, 0, 2] where !isCancelled() {
            let pixels = split.groups[tone]
            if fitMaskColor(masks[tone].0, components: masks[tone].1, target: reference.toneColors[tone],
                            in: &settings, measure: measure, isCancelled: isCancelled,
                            color: { LookSkin.meanAB($0, pixels) }) {
                matched = true
            }
        }
        return matched
    }

    /// Adds (or reuses) the mask `name` made of `components` and fits its Temp, Tint and
    /// Saturation so `color` of the render comes to `target`. Temp and Tint are solved together
    /// because their color directions overlap, then Saturation refines it; each step is kept only
    /// when it brings the color closer. A mask that moved nothing isn't added. True when the color
    /// was already close or came closer.
    private static func fitMaskColor(_ name: String, components: [DevelopSettings.MaskComponent],
                                     target: SIMD2<Double>, in settings: inout DevelopSettings,
                                     measure: (DevelopSettings) -> LookSample?, isCancelled: () -> Bool,
                                     color colorOf: (LookSample) -> SIMD2<Double>?) -> Bool {
        func color(_ candidate: DevelopSettings) -> SIMD2<Double>? {
            guard !isCancelled(), let sample = measure(candidate) else { return nil }
            return colorOf(sample)
        }
        guard var measured = color(settings) else { return false }
        let tolerance = 0.002
        var error = target - measured
        if (error * error).sum() < tolerance * tolerance { return true }

        let existing = settings.masks.firstIndex { $0.name == name }
        let index = existing ?? settings.masks.count
        var best = settings
        if existing == nil {
            best.masks.append(.init(name: name, components: components))
        } else {
            // A repeat match keeps the mask (and its id) but takes the faces as found now.
            best.masks[index].components = components
        }

        // Each slider's effect on the color is measured once (three renders) and reused for
        // every step: the response is close to linear over this range, and each render with
        // masks is the slow part of a match.
        func slope(_ parameter: DevelopSettings.LocalParameter) -> SIMD2<Double> {
            var trial = best
            let value = trial.masks[index][parameter]
            let step = value > 85 ? -12.0 : 12.0
            trial.masks[index][parameter] = value + step
            guard let result = color(trial) else { return .zero }
            return (result - measured) / step
        }
        let temp = slope(.temperature), tint = slope(.tint), saturation = slope(.saturation)
        let determinant = temp.x * tint.y - tint.x * temp.y
        let response = (saturation * saturation).sum()

        var improved = false
        func tryStep(_ changes: [(DevelopSettings.LocalParameter, Double)]) {
            for fraction in [1.0, 0.5] {
                var trial = best
                for (parameter, delta) in changes {
                    let value = trial.masks[index][parameter]
                    trial.masks[index][parameter] = (value + min(30, max(-30, delta)) * fraction).rounded()
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
        for _ in 0..<2 {
            if abs(determinant) > 1e-10 {
                tryStep([(.temperature, (error.x * tint.y - error.y * tint.x) / determinant),
                         (.tint, (temp.x * error.y - temp.y * error.x) / determinant)])
            }
            if response > 1e-10 {
                tryStep([(.saturation, (error * saturation).sum() / response)])
            }
            if (error * error).sum() < tolerance * tolerance || isCancelled() { break }
        }

        if improved { settings = best }
        return improved
    }

    private static func colorVector(hue: Double, chroma: Double) -> SIMD2<Double> {
        let angle = hue * .pi / 180
        return SIMD2(cos(angle), sin(angle)) * chroma
    }
}
