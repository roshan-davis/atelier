import AppKit
import AtelierCore
import SwiftUI

/// Basic > White Balance: Lightroom's WB menu (As Shot, Auto, the presets, Custom) and the
/// White Balance Selector.
struct WhiteBalanceRow: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        HStack(spacing: 8) {
            Text("WB")
                .frame(width: 78, alignment: .leading)
            Menu(develop.whiteBalanceName) {
                Button("As Shot") { develop.setWhiteBalanceAsShot() }
                Button("Auto") { develop.findWhiteBalance() }
                if develop.isRAW {
                    Divider()
                    ForEach(WhiteBalance.presets) { preset in
                        Button(preset.name) { develop.applyWhiteBalance(preset) }
                    }
                }
            }
            .controlSize(.small)
            .help(develop.isRAW ? "White balance presets, as in Lightroom. Auto is ⇧⌘U."
                  : "As Shot or Auto (⇧⌘U). Presets apply to RAW files.")
            if develop.isFindingWhiteBalance {
                ProgressView().controlSize(.mini)
            }
            Button {
                develop.isPickingWhiteBalance.toggle()
            } label: {
                Image(systemName: "eyedropper")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(develop.isPickingWhiteBalance ? Color.accentColor : Color.secondary)
            .help("White Balance Selector (W): click something in the photo that should be neutral gray or white")
        }
        .font(.callout)
        .disabled(develop.assetID == nil)
    }
}

/// The photo while the White Balance Selector is out: a click makes that spot neutral and puts
/// the selector away, as Lightroom does by default. Esc or W puts it away without a change.
struct WhiteBalancePickerView: View {
    @ObservedObject var develop: DevelopController
    let image: NSImage

    var body: some View {
        GeometryReader { geometry in
            let rect = AIBrushView.fit(image.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Text("Click something that should be neutral gray or white. Esc to cancel.")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: geometry.size.width / 2, y: 22)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard rect.contains(location), rect.width > 0, rect.height > 0 else { return }
                develop.findWhiteBalance(at: CGPoint(x: (location.x - rect.minX) / rect.width,
                                                     y: (location.y - rect.minY) / rect.height))
            }
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
        }
    }
}
