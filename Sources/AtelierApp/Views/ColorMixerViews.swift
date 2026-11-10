import AppKit
import AtelierCore
import SwiftUI

/// HSL / Color, as Lightroom's Color Mixer: the Mixer (eight color bands, shown one channel at a
/// time or all at once) and Point Color (pick a color in the photo and change just that color).
/// In Black & White the B&W Mix takes its place. The Targeted Adjustment Tool drags on the photo
/// to move the bands under the pointer.
struct HSLPanel: View {
    @ObservedObject var develop: DevelopController
    @AppStorage("develop.hslChannel") private var channel = "Hue"
    @AppStorage("develop.colorMixerView") private var view = "mixer"

    private var channels: [DevelopSettings.HSLChannel] {
        channel == "All" ? DevelopSettings.HSLChannel.allCases
            : [DevelopSettings.HSLChannel(rawValue: channel) ?? .hue]
    }

    var body: some View {
        if develop.settings.monochrome {
            bwBody
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Picker("View", selection: $view) {
                    Text("Mixer").tag("mixer")
                    Text("Point Color").tag("point")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                if view == "point" {
                    PointColorView(develop: develop)
                } else {
                    mixerBody
                }
            }
        }
    }

    /// Black & White: the B&W Mix takes HSL's place, as in Lightroom.
    private var bwBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                GroupHeading(title: "B&W Mix") {
                    develop.reset(group: "B&W Mix", parameters: DevelopSettings.ColorBand.allCases.map { .gray($0) })
                }
                Spacer()
                PickerButton(develop: develop, kind: .targetGray, symbol: "scope",
                             help: "Targeted Adjustment: drag up or down on a color in the photo to make its gray lighter or darker")
            }
            ForEach(DevelopSettings.ColorBand.allCases, id: \.self) { band in
                ParameterSlider(parameter: .gray(band), develop: develop)
            }
            Text("Each slider makes that color lighter or darker in gray.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mixerBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                targetButton
                // Lightroom's full names when they fit; in a narrow panel "Sat" and "Lum", so the
                // row never pushes the panel wider than its column (Rosh saw HSL cut off on the
                // left, Nov 10, 2026).
                ViewThatFits(in: .horizontal) {
                    channelPicker(short: false)
                    channelPicker(short: true)
                }
            }
            ForEach(channels, id: \.self) { channel in
                if channels.count > 1 {
                    GroupHeading(title: channel.rawValue) {
                        develop.reset(group: channel.rawValue,
                                      parameters: DevelopSettings.ColorBand.allCases.map { .hsl(channel, $0) })
                    }
                }
                ForEach(DevelopSettings.ColorBand.allCases, id: \.self) { band in
                    ParameterSlider(parameter: .hsl(channel, band), develop: develop)
                }
            }
        }
        .onChange(of: channel) {
            if let shown = DevelopSettings.HSLChannel(rawValue: channel) { develop.targetChannel = shown }
        }
    }

    private func channelPicker(short: Bool) -> some View {
        Picker("Channel", selection: $channel) {
            ForEach(DevelopSettings.HSLChannel.allCases, id: \.self) { option in
                Text(short ? Self.shortName(option) : option.rawValue).tag(option.rawValue)
            }
            Text("All").tag("All")
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .help("Hue, Saturation, Luminance, or All three")
    }

    private static func shortName(_ channel: DevelopSettings.HSLChannel) -> String {
        switch channel {
        case .hue: return "Hue"
        case .saturation: return "Sat"
        case .luminance: return "Lum"
        }
    }

    /// The Targeted Adjustment Tool: for the channel shown, or in All, the one picked from its menu.
    @ViewBuilder
    private var targetButton: some View {
        if let shown = DevelopSettings.HSLChannel(rawValue: channel) {
            PickerButton(develop: develop, kind: .targetColor, symbol: "scope",
                         help: "Targeted Adjustment: drag up or down on a color in the photo to change its \(shown.rawValue.lowercased())") {
                develop.targetChannel = shown
            }
        } else {
            Menu {
                ForEach(DevelopSettings.HSLChannel.allCases, id: \.self) { option in
                    Button(option.rawValue) {
                        develop.targetChannel = option
                        develop.picker = .targetColor
                    }
                }
                if develop.picker == .targetColor {
                    Divider()
                    Button("Put Away") { develop.picker = nil }
                }
            } label: {
                Image(systemName: "scope")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(develop.picker == .targetColor ? Color.accentColor : Color.secondary)
            .disabled(develop.assetID == nil)
            .help("Targeted Adjustment: choose Hue, Saturation or Luminance, then drag up or down on a color in the photo")
        }
    }
}

/// Lightroom's Point Color: up to four swatches, each a color picked in the photo with its own
/// Hue, Saturation and Luminance shift, Range and (from Capture One's skin tone tool) Uniformity.
private struct PointColorView: View {
    @ObservedObject var develop: DevelopController

    private var swatch: Int { develop.pointColorSwatch }
    private let sliders: [DevelopSettings.PointColorSetting] = [.hueShift, .satShift, .lumShift]
    private let rangeSliders: [DevelopSettings.PointColorSetting] = [.range, .uniformity]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PickerButton(develop: develop, kind: .pointColor,
                             help: "Pick a color: click the color in the photo you want to change")
                ForEach(0..<DevelopSettings.pointColorCount, id: \.self) { index in
                    swatchButton(index)
                }
                Spacer(minLength: 0)
            }
            if develop.settings.hasPointColor(swatch) {
                GroupHeading(title: "Point Color \(swatch + 1)") {
                    develop.reset(group: "Point Color \(swatch + 1)",
                                  parameters: (sliders + rangeSliders).map { .pointColor(swatch, $0) })
                }
                ForEach(sliders, id: \.self) { setting in
                    ParameterSlider(parameter: .pointColor(swatch, setting), develop: develop)
                }
                GroupHeading(title: "Range")
                ForEach(rangeSliders, id: \.self) { setting in
                    ParameterSlider(parameter: .pointColor(swatch, setting), develop: develop)
                }
                Toggle("Visualize Range", isOn: $develop.visualizesPointRange)
                    .controlSize(.small)
                    .help("Shows only the colors this swatch changes; everything else turns gray")
                Text("Range widens or narrows the colors that change. Uniformity evens them out toward the picked color, "
                     + "for blotchy skin or a patchy sky.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Click the eyedropper, then the color in the photo you want to change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { develop.visualizesPointRange = false }
    }

    private func swatchButton(_ index: Int) -> some View {
        let color = TargetedAdjustment.swatchColor(develop.settings, swatch: index)
        return Button {
            develop.pointColorSwatch = index
        } label: {
            ZStack {
                if let color {
                    Circle().fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue))
                } else {
                    Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(Circle().strokeBorder(index == swatch ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color == nil ? "Empty swatch: select it, then pick a color with the eyedropper"
              : "Point Color \(index + 1). Right-click to delete it.")
        .contextMenu {
            if color != nil {
                Button("Delete Point Color \(index + 1)") { develop.deletePointColor(index) }
            }
        }
    }
}
