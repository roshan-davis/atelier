import AppKit
import SwiftUI

/// The app's look, chosen in Settings > Appearance. Light and Dark follow macOS's own styles;
/// the others are dark styles tuned for judging photos, like Lightroom's grays.
enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark, graphite, darkroom, neutralGray

    static let defaultsKey = "appearance.theme"

    var id: String { rawValue }

    static var current: Theme {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Theme.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .graphite: return "Graphite"
        case .darkroom: return "Darkroom"
        case .neutralGray: return "Neutral Gray"
        }
    }

    var summary: String {
        switch self {
        case .system: return "Follows macOS: light or dark."
        case .light: return "Light window, light gray around the photo."
        case .dark: return "macOS dark style."
        case .graphite: return "Charcoal panels and a dark surround, like Lightroom."
        case .darkroom: return "Near black everywhere, so only the photo stands out."
        case .neutralGray: return "Dark panels with a mid-gray surround, for judging color and brightness."
        }
    }

    /// The macOS appearance the whole app uses; nil follows the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark, .graphite, .darkroom, .neutralGray: return .darkAqua
        }
    }

    /// Behind the photo in loupe and develop, and behind the grid.
    var surround: NSColor {
        switch self {
        case .system, .light, .dark: return .underPageBackgroundColor
        case .graphite: return NSColor(white: 0.12, alpha: 1)
        case .darkroom: return NSColor(white: 0.03, alpha: 1)
        case .neutralGray: return NSColor(white: 0.46, alpha: 1)
        }
    }

    var gridBackground: NSColor {
        switch self {
        case .system, .light, .dark: return .windowBackgroundColor
        case .neutralGray: return NSColor(white: 0.2, alpha: 1)
        default: return surround
        }
    }

    /// The right panel's background.
    var panel: NSColor {
        switch self {
        case .system, .light, .dark: return .controlBackgroundColor
        case .graphite: return NSColor(white: 0.17, alpha: 1)
        case .darkroom: return NSColor(white: 0.08, alpha: 1)
        case .neutralGray: return NSColor(white: 0.22, alpha: 1)
        }
    }

    /// Behind the filter bar, the bars under the photo and the status bar.
    var chrome: NSColor {
        switch self {
        case .system, .light, .dark: return .windowBackgroundColor
        default: return panel
        }
    }

    /// Sets the appearance for every window, Settings included.
    @MainActor func apply() {
        NSApp.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.system
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
