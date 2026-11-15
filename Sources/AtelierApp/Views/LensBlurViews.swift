import AppKit
import AtelierCore
import SwiftUI

/// Lens Blur, as in Lightroom: Apply, Blur Amount, the Bokeh shapes with Cat Eye and Boost, and
/// the Focal Range on a near-to-far depth strip, set by the focus picker (click the photo) or
/// Subject; Visualize Depth shows the depth on the photo. It runs on the depth model, so before
/// that is downloaded the panel offers it.
struct LensBlurPanel: View {
    @ObservedObject var develop: DevelopController

    private let bokeh: [DevelopSettings.Parameter] = [.lensBlurBokeh, .lensBlurCatEye, .lensBlurBoost]
    private let focus: [DevelopSettings.Parameter] = [.lensBlurFocusNear, .lensBlurFocusFar]

    private var applied: Binding<Bool> {
        Binding(get: { develop.value(.lensBlurApply) >= 0.5 }, set: { develop.setLensBlurApplied($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            DepthModelGate {
                VStack(alignment: .leading, spacing: 7) {
                    blur
                    bokehControls
                    focalRange
                }
            }
        }
        .onDisappear { develop.visualizesDepth = false }
    }

    private var blur: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Apply", isOn: applied)
                .toggleStyle(.checkbox)
                .help("Blurs the photo as a wide-open lens would, from how far away each part is")
            ParameterSlider(parameter: .lensBlurAmount, develop: develop)
        }
    }

    private var bokehControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroupHeading(title: "Bokeh") { develop.reset(group: "Bokeh", parameters: bokeh) }
            HStack(spacing: 8) {
                Text(DevelopSettings.Parameter.lensBlurBokeh.label)
                    .frame(width: 78, alignment: .leading)
                    .contentShape(Rectangle())
                    .onDoubleClick { develop.reset(.lensBlurBokeh) }
                IconSegmentedControl(segments: LensBlur.Bokeh.allCases.map { shape in
                    IconSegmentedControl<Int>.Segment(value: shape.rawValue, symbol: Self.symbol(shape),
                                                      help: "\(shape.title): \(shape.detail)")
                }, selection: Binding(get: { Int(develop.value(.lensBlurBokeh).rounded()) },
                                      set: { develop.set(.lensBlurBokeh, to: Double($0)) }))
                .fixedSize()
                Spacer(minLength: 0)
            }
            .font(.callout)
            ParameterSlider(parameter: .lensBlurCatEye, develop: develop)
                .help("Cuts the bokeh toward the photo's edges into cat's-eye shapes, the swirl of an old lens")
            ParameterSlider(parameter: .lensBlurBoost, develop: develop)
                .help("Brightens the brightest highlights before the blur, so they read as bokeh")
        }
    }

    private var focalRange: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroupHeading(title: "Focal Range") { develop.reset(group: "Focal Range", parameters: focus) }
            DepthStrip(low: develop.value(.lensBlurFocusNear), high: develop.value(.lensBlurFocusFar))
                .frame(height: 10)
            ForEach(focus, id: \.self) { ParameterSlider(parameter: $0, develop: develop) }
            HStack(spacing: 10) {
                PickerButton(develop: develop, kind: .lensFocus, symbol: "scope",
                             help: "Focus picker: click the part of the photo to keep in focus")
                Button("Subject") { develop.focusLensBlurOnSubject() }
                    .controlSize(.small)
                    .help("Keeps the photo's subject in focus, as Select Subject finds it")
                Spacer(minLength: 0)
                Toggle("Visualize Depth", isOn: $develop.visualizesDepth)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help(SliderPreview.visualizeDepth.hint)
            }
            if let message = develop.lensBlurMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("0 is the nearest part of the photo, 100 the farthest. Parts outside the Focal Range blur more the farther they are from it, in front as well as behind.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func symbol(_ shape: LensBlur.Bokeh) -> String {
        switch shape {
        case .circle: return "circle.fill"
        case .bubble: return "circle"
        case .fiveBlade: return "pentagon.fill"
        case .ring: return "circle.circle"
        case .anamorphic: return "oval.portrait.fill"
        }
    }
}
