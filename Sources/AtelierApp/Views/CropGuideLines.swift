import AppKit
import AtelierCore
import SwiftUI

/// Draws crop guide lines in the person's look: a contrast edge one point wider, then the line.
/// Shared by the crop tool and the preview in Settings > Develop > Crop Overlay.
struct CropGuideLines: View {
    let path: Path
    let look: CropGuideLook
    var dragging = false

    var body: some View {
        let edge = look.edgeIsDark ? Color.black : Color.white
        ZStack {
            path.stroke(edge.opacity(look.edgeOpacity), lineWidth: look.width + 1)
            path.stroke(Color(.sRGB, red: look.red, green: look.green, blue: look.blue)
                            .opacity(dragging ? look.dragOpacity : look.opacity),
                        lineWidth: look.width)
        }
        .allowsHitTesting(false)
    }
}

/// The three @AppStorage values of the lines' look, for views that draw or edit them.
extension CropGuideLook {
    /// sRGB color for a `ColorPicker`.
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// "#RRGGBB" of a color chosen in a `ColorPicker`, in sRGB.
    static func hex(of color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return CropGuideLook(width: 1, opacity: 1, red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                             blue: Double(rgb.blueComponent)).hex
    }
}
