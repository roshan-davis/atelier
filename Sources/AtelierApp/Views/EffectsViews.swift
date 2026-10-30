import AppKit
import AtelierCore
import SwiftUI

/// Effects, as in Lightroom: Post-Crop Vignetting (Style, Amount, Midpoint, Roundness, Feather,
/// Highlights), Glow (Diffusion, Bloom, Halation) and Grain.
struct EffectsPanel: View {
    @ObservedObject var develop: DevelopController

    private let vignette: [DevelopSettings.Parameter] = [.vignetteStyle, .vignette, .vignetteMidpoint, .vignetteRoundness,
                                                         .vignetteFeather, .vignetteHighlights]
    private let glow: [DevelopSettings.Parameter] = [.glowStyle, .glowAmount, .glowRange, .glowSpread, .glowWarmth]
    private let grain: [DevelopSettings.Parameter] = [.grain, .grainSize, .grainRoughness]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroupHeading(title: "Post-Crop Vignetting") { develop.reset(group: "Post-Crop Vignetting", parameters: vignette) }
            StyleRow(develop: develop, parameter: .vignetteStyle,
                     options: DevelopSettings.VignetteStyle.allCases.map { ($0.rawValue, $0.title) })
                .help("Highlight Priority keeps bright areas bright; Color Priority keeps hues; Paint Overlay mixes in black or white")
            ForEach([DevelopSettings.Parameter.vignette, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather], id: \.self) {
                ParameterSlider(parameter: $0, develop: develop)
            }
            ParameterSlider(parameter: .vignetteHighlights, develop: develop)
                .disabled(develop.settings.vignette >= 0 || develop.settings.vignetteStyle == .paintOverlay)
                .help("Brings back bright areas in darkened corners (Highlight and Color Priority, negative Amount)")

            GroupHeading(title: "Glow") { develop.reset(group: "Glow", parameters: glow) }
            StyleRow(develop: develop, parameter: .glowStyle,
                     options: DevelopSettings.GlowStyle.allCases.map { ($0.rawValue, $0.title) })
                .help("Diffusion: a soft haze. Bloom: light spills from highlights. Halation: film's red glow around highlights.")
            ForEach([DevelopSettings.Parameter.glowAmount, .glowRange, .glowSpread, .glowWarmth], id: \.self) {
                ParameterSlider(parameter: $0, develop: develop)
            }

            GroupHeading(title: "Grain") { develop.reset(group: "Grain", parameters: grain) }
            ForEach(grain, id: \.self) {
                ParameterSlider(parameter: $0, develop: develop)
            }
        }
    }
}

/// A Style menu in a slider's layout: the name, then the choices.
private struct StyleRow: View {
    @ObservedObject var develop: DevelopController
    let parameter: DevelopSettings.Parameter
    let options: [(Int, String)]

    var body: some View {
        HStack(spacing: 8) {
            Text(parameter.label)
                .frame(width: 78, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { develop.reset(parameter) }
            Picker(parameter.label, selection: Binding(get: { Int(develop.value(parameter).rounded()) },
                                                      set: { develop.set(parameter, to: Double($0)) })) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .font(.callout)
    }
}
