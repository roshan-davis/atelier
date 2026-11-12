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
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
