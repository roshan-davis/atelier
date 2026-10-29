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
            PickerButton(develop: develop, kind: .whiteBalance,
                         help: "White Balance Selector (W): click something in the photo that should be neutral gray or white")
        }
        .font(.callout)
        .disabled(develop.assetID == nil)
    }
}
