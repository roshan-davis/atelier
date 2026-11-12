import SwiftUI

/// A section of a Settings pane that opens and closes like the panels in the main window:
/// the same `SectionBand` header (click it to minimize or show), inside the pane's grouped Form,
/// so rows keep the Form's label-and-control alignment. Closed sections are remembered.
struct SettingsSection<Content: View, Footer: View, Trailing: View>: View {
    let title: String
    /// Remembers the open state; the title unless two sections could share one.
    let id: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let trailing: () -> Trailing

    @AppStorage(SettingsSectionState.defaultsKey) private var collapsed = ""

    init(_ title: String, id: String? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.id = id
        self.content = content
        self.footer = footer
        self.trailing = trailing
    }

    var body: some View {
        let key = id ?? title
        let isExpanded = Binding(
            get: { !SettingsSectionState.isCollapsed(key, in: collapsed) },
            set: { collapsed = SettingsSectionState.setting(key, collapsed: !$0, in: collapsed) })
        Section {
            if isExpanded.wrappedValue { content() }
        } header: {
            SectionBand(title: title, isExpanded: isExpanded) { _ in trailing() }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } footer: {
            if isExpanded.wrappedValue { footer() }
        }
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(_ title: String, id: String? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.init(title, id: id, content: content, footer: footer, trailing: { EmptyView() })
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: String, id: String? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title, id: id, content: content, footer: { EmptyView() }, trailing: trailing)
    }
}

extension SettingsSection where Footer == EmptyView, Trailing == EmptyView {
    init(_ title: String, id: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, id: id, content: content, footer: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// Which Settings sections are closed, as one user default (ids, one per line).
enum SettingsSectionState {
    static let defaultsKey = "settings.collapsedSections"

    static func isCollapsed(_ id: String, in stored: String) -> Bool {
        stored.split(separator: "\n").contains { $0 == id }
    }

    static func setting(_ id: String, collapsed: Bool, in stored: String) -> String {
        var ids = stored.split(separator: "\n").map(String.init).filter { $0 != id }
        if collapsed { ids.append(id) }
        return ids.joined(separator: "\n")
    }
}

/// A pane's icon: a white symbol on the pane's color, as in System Settings, so it reads on
/// every theme (an accent-colored symbol alone disappeared on the dark themes).
struct SettingsIconTile: View {
    let pane: SettingsPane
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(pane.tint, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// Soft, muted colors for Settings' icon tiles and the keyboard map (Rosh, Nov 12, 2026: the
/// system colors were too bright). Mid-light and low in saturation, so they read on light and
/// dark themes without glaring, and white symbols stay legible on them.
enum SettingsPalette {
    static let slate = Color(red: 0.56, green: 0.59, blue: 0.64)
    static let lavender = Color(red: 0.62, green: 0.56, blue: 0.78)
    static let periwinkle = Color(red: 0.52, green: 0.57, blue: 0.80)
    static let sky = Color(red: 0.47, green: 0.64, blue: 0.82)
    static let peach = Color(red: 0.86, green: 0.63, blue: 0.47)
    static let sage = Color(red: 0.52, green: 0.70, blue: 0.56)
    static let seafoam = Color(red: 0.44, green: 0.68, blue: 0.68)
    static let rose = Color(red: 0.82, green: 0.54, blue: 0.62)
    static let mist = Color(red: 0.47, green: 0.69, blue: 0.78)
    static let coral = Color(red: 0.86, green: 0.48, blue: 0.47)
    static let butter = Color(red: 0.88, green: 0.77, blue: 0.43)
    static let amber = Color(red: 0.88, green: 0.70, blue: 0.42)
}
