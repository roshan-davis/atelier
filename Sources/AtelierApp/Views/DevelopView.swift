import AppKit
import AtelierCore
import SwiftUI

/// The photo being developed, rendered live from the original, with optional before/after views.
struct DevelopImageView: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var develop: DevelopController

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if let image = develop.image {
                    if develop.showingBefore || develop.compareMode == .off {
                        PhotoImage(image: image)
                            .padding(16)
                    } else if develop.compareMode == .sideBySide {
                        HStack(spacing: 12) {
                            ComparePane(image: develop.beforeImage, label: "Before")
                            ComparePane(image: image, label: "After")
                        }
                        .padding(16)
                    } else {
                        SliderCompareView(before: develop.beforeImage, after: image, position: $develop.sliderPosition)
                            .padding(16)
                    }
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
                    Badge(text: "Before").padding(14)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("Before and After")
                    .foregroundStyle(.secondary)
                Picker("Before and After", selection: $develop.compareMode) {
                    ForEach(CompareMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Compare with the original: side by side, or drag a slider across the photo (Y)")
                Spacer()
                if develop.compareMode == .slider {
                    Text("Drag across the photo to move the divider")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onAppear { develop.open(model.focusedID) }
    }
}

private struct PhotoImage: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
    }
}

private struct ComparePane: View {
    let image: NSImage?
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                PhotoImage(image: image)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Badge(text: label).padding(8)
        }
    }
}

/// The edited photo with the original revealed to the left of a draggable divider.
private struct SliderCompareView: View {
    let before: NSImage?
    let after: NSImage
    @Binding var position: Double

    var body: some View {
        GeometryReader { geometry in
            let rect = fittedRect(for: after.size, in: geometry.size)
            let dividerX = rect.minX + rect.width * position
            ZStack(alignment: .topLeading) {
                Image(nsImage: after)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                if let before {
                    Image(nsImage: before)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: rect.width * position)
                        }
                        .position(x: rect.midX, y: rect.midY)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: rect.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: dividerX, y: rect.midY)
                Circle()
                    .fill(Color.white)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(Color.black))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .position(x: dividerX, y: rect.midY)
                Badge(text: "Before")
                    .fixedSize()
                    .position(x: rect.minX + 44, y: rect.minY + 20)
                    .opacity(position > 0.12 ? 1 : 0)
                Badge(text: "After")
                    .fixedSize()
                    .position(x: rect.maxX - 38, y: rect.minY + 20)
                    .opacity(position < 0.88 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard rect.width > 0 else { return }
                position = min(1, max(0, (value.location.x - rect.minX) / rect.width))
            })
        }
    }

    private func fittedRect(for size: NSSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
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
