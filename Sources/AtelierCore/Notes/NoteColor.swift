import Foundation

/// The sticky note's paper color (Settings > Appearance > Notes): the classic sticky-note
/// colors, or any color picked. Pure sRGB numbers, so the app turns them into `NSColor`.
public enum NoteColor: String, CaseIterable, Codable, Sendable {
    case yellow, pink, green, blue, orange, purple, custom

    public static let defaultOpacity = 0.85
    public static let opacityRange = 0.5...1.0

    public var title: String {
        switch self {
        case .yellow: return "Yellow"
        case .pink: return "Pink"
        case .green: return "Green"
        case .blue: return "Blue"
        case .orange: return "Orange"
        case .purple: return "Purple"
        case .custom: return "Custom"
        }
    }

    /// The preset's paper, as the familiar sticky-note pads; nil for `custom`.
    public var preset: RGB? {
        switch self {
        case .yellow: return RGB(hex: "FFEB6B")
        case .pink: return RGB(hex: "FF9FC9")
        case .green: return RGB(hex: "B9F18C")
        case .blue: return RGB(hex: "9CDCF8")
        case .orange: return RGB(hex: "FFC069")
        case .purple: return RGB(hex: "D5B8FF")
        case .custom: return nil
        }
    }

    /// The paper for this choice; `custom` uses `customHex`, falling back to yellow.
    public func paper(customHex: String) -> RGB {
        preset ?? RGB(hex: customHex) ?? Self.yellow.preset!
    }

    public struct RGB: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = min(max(red, 0), 1)
            self.green = min(max(green, 0), 1)
            self.blue = min(max(blue, 0), 1)
        }

        /// "FFEB6B" or "#ffeb6b"; nil for anything else.
        public init?(hex: String) {
            var text = hex.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") { text.removeFirst() }
            guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
            self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
        }

        public var hex: String {
            String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
                   Int((blue * 255).rounded()))
        }

        /// Relative luminance (sRGB, WCAG).
        public var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// The header strip: the same paper a little deeper, as a pad's glued edge.
        public var header: RGB {
            RGB(red: red * 0.93, green: green * 0.90, blue: blue * 0.80)
        }

        /// Dark ink on light paper, light ink on a dark custom color.
        public var inkIsDark: Bool { luminance > 0.28 }
    }
}
