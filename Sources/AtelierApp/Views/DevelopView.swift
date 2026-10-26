import AppKit
import AtelierCore
import SwiftUI

/// The photo being developed, rendered live from the original.
struct DevelopImageView: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var develop: DevelopController

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .underPageBackgroundColor)
            if let image = develop.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if develop.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = develop.errorMessage {
                Text(message)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if develop.showingBefore {
                Text("Before")
                    .font(.callout.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(14)
            }
        }
        .onAppear { develop.open(model.focusedID) }
    }
}

/// The Basic panel, shown in the right column while developing.
struct DevelopPanel: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var develop: DevelopController

    private var groups: [(String, [DevelopSettings.Parameter])] {
        var result: [(String, [DevelopSettings.Parameter])] = []
        for parameter in DevelopSettings.Parameter.allCases {
            if result.last?.0 == parameter.group {
                result[result.count - 1].1.append(parameter)
            } else {
                result.append((parameter.group, [parameter]))
            }
        }
        return result
    }

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.self) { parameter in
                        ParameterSlider(parameter: parameter, develop: develop)
                    }
                }
            }

            Section {
                HStack {
                    Button("Reset All") { develop.resetAll() }
                    Spacer()
                    Toggle("Before", isOn: $develop.showingBefore)
                        .toggleStyle(.button)
                        .help("Show the photo without edits (\\)")
                }
                HStack {
                    Button("Copy Settings") { develop.copySettings() }
                    Button("Paste Settings") { develop.pasteSettings() }
                        .disabled(develop.clipboard == nil)
                }
            } footer: {
                Text("Edits are saved automatically and never change the original. Double-click a slider's name to reset it.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .disabled(develop.assetID == nil)
    }
}

private struct ParameterSlider: View {
    let parameter: DevelopSettings.Parameter
    @ObservedObject var develop: DevelopController

    private var binding: Binding<Double> {
        Binding(get: { develop.value(parameter) }, set: { develop.set(parameter, to: $0) })
    }

    private var formatted: String {
        let value = develop.value(parameter)
        switch parameter {
        case .temperature: return "\(Int(value.rounded())) K"
        case .exposure: return String(format: "%+.2f", value)
        default: return value == 0 ? "0" : String(format: "%+.0f", value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(parameter.label)
                    .onTapGesture(count: 2) { develop.reset(parameter) }
                    .help("Double-click to reset")
                Spacer()
                Text(formatted)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: parameter.range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var step: Double {
        switch parameter {
        case .temperature: return 50
        case .exposure: return 0.05
        default: return 1
        }
    }
}
