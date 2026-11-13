import Foundation

/// Which side panels fit while Atelier's window is docked beside a chat app (AT-050h), or is
/// still narrow after it was let go. The photo keeps its room; the left panel goes first (the
/// right one holds Develop's sliders), then the right one. Panels come back as the width allows.
public struct DockLayout: Equatable, Sendable {
    public var showsSidebar: Bool
    public var showsInspector: Bool

    public init(showsSidebar: Bool, showsInspector: Bool) {
        self.showsSidebar = showsSidebar
        self.showsInspector = showsInspector
    }

    /// Both panels, as when nothing constrains the window.
    public static let full = DockLayout(showsSidebar: true, showsInspector: true)

    /// The photo's narrowest width beside the panels that stay.
    public static let photoMinimum: Double = 480
    /// The narrowest window Atelier docks at: the photo alone, both panels collapsed.
    public static let minimumWidth: Double = 520

    /// The panels that fit a window `width` points wide. `sidebar` and `inspector` are the
    /// panels' widths as they are now (0 for a panel the person has hidden).
    public static func fitting(width: Double, sidebar: Double, inspector: Double) -> DockLayout {
        if width >= sidebar + inspector + photoMinimum { return .full }
        if width >= inspector + photoMinimum { return DockLayout(showsSidebar: false, showsInspector: true) }
        return DockLayout(showsSidebar: false, showsInspector: false)
    }
}
