import SwiftUI

struct SectionBand<Trailing: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var isModified = false
    @ViewBuilder var trailing: (_ hovering: Bool) -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(isExpanded ? .primary : .secondary)
                .lineLimit(1)
            if isModified {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .padding(.leading, 4)
                    .help("This section has edits")
            }
            Spacer(minLength: 6)
            trailing(hovering)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Color.primary.opacity(hovering ? 0.09 : 0.05))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        }
        .onHover { hovering = $0 }
        .help(isExpanded ? "Click to minimize \(title)" : "Click to show \(title)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: isExpanded ? "Minimize" : "Show") { isExpanded.toggle() }
    }
}

/// Small borderless icon buttons for a sidebar header band.
struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarIconButton(configuration: configuration)
    }

    private struct SidebarIconButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.18 : (hovering && isEnabled ? 0.1 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

