import AtelierCore
import SwiftUI

/// The left column in Develop, as in Lightroom: presets, snapshots and the edit history of the
/// open photo.
struct DevelopSidebar: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var develop: DevelopController
    @State private var naming: NameRequest?
    @State private var nameText = ""

    private enum NameRequest: Identifiable {
        case newSnapshot
        case renameSnapshot(UUID)

        var id: String {
            switch self {
            case .newSnapshot: return "new"
            case .renameSnapshot(let id): return id.uuidString
            }
        }
    }

    /// Sections minimized by clicking their header, remembered between launches.
    @AppStorage("develop.sidebarCollapsed") private var collapsedList = ""

    private static let sections = ["navigator", "presets", "snapshots", "history"]

    private func isExpanded(_ section: String) -> Binding<Bool> {
        Binding(get: { !collapsedList.split(separator: ",").contains(Substring(section)) }, set: { open in
            var collapsed = Set(collapsedList.split(separator: ",").map(String.init))
            if open { collapsed.remove(section) } else { collapsed.insert(section) }
            collapsedList = collapsed.sorted().joined(separator: ",")
        })
    }

    var body: some View {
        // A plain stack rather than a List: List rebuilds its rows, which made the presets'
        // sheets flash as they closed.
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                SidebarSection(title: "Navigator", isExpanded: isExpanded("navigator")) {
                    EmptyView()
                } content: {
                    NavigatorView(develop: develop)
                }
                PresetsSection(develop: develop, isExpanded: isExpanded("presets"))

                SidebarSection(title: "Snapshots", isExpanded: isExpanded("snapshots")) {
                    Button {
                        nameText = Date().formatted(date: .abbreviated, time: .shortened)
                        naming = .newSnapshot
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Create a snapshot of the current settings")
                    .disabled(develop.assetID == nil)
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        if develop.history.snapshots.isEmpty {
                            Text("Save the current look to come back to it later.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(develop.history.snapshots) { snapshot in
                            SidebarRow {
                                Label(snapshot.name, systemImage: "camera.viewfinder")
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .onTapGesture { develop.applySnapshot(snapshot) }
                            .help("Created \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). Click to apply.")
                            .contextMenu {
                                Button("Apply") { develop.applySnapshot(snapshot) }
                                Button("Update with Current Settings") { develop.updateSnapshot(snapshot.id) }
                                Button("Rename…") {
                                    nameText = snapshot.name
                                    naming = .renameSnapshot(snapshot.id)
                                }
                                Divider()
                                Button("Delete", role: .destructive) { develop.deleteSnapshot(snapshot.id) }
                            }
                        }
                    }
                }

                SidebarSection(title: "History", isExpanded: isExpanded("history")) {
                    Button {
                        develop.clearHistory()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Clear the history, keeping the current settings")
                    .disabled(develop.history.steps.count < 2)
                } content: {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if develop.history.steps.isEmpty {
                            Text("Edits you make appear here. Click one to go back to it.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(develop.history.steps.enumerated()).reversed(), id: \.offset) { index, step in
                            SidebarRow(isCurrent: index == develop.history.position) {
                                HistoryRow(step: step, isCurrent: index == develop.history.position,
                                           isUndone: index > develop.history.position)
                            }
                            .onTapGesture { develop.go(to: index) }
                        }
                    }
                }
            }
        }
        .contextMenu {
            Button("Expand All Sections") { collapsedList = "" }
            Button("Collapse All Sections") { collapsedList = Self.sections.joined(separator: ",") }
        }
        .alert(alertTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(alertAction) { commitName() }
                .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var alertTitle: String {
        if case .renameSnapshot = naming { return "Rename Snapshot" }
        return "New Snapshot"
    }

    private var alertAction: String {
        if case .renameSnapshot = naming { return "Rename" }
        return "Create"
    }

    private func commitName() {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch naming {
        case .newSnapshot: develop.createSnapshot(named: name)
        case .renameSnapshot(let id): develop.renameSnapshot(id, to: name)
        case nil: break
        }
        naming = nil
    }
}

private struct HistoryRow: View {
    let step: DevelopHistory.Step
    let isCurrent: Bool
    let isUndone: Bool

    var body: some View {
        HStack {
            Text(step.name)
                .lineLimit(1)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isUndone ? .tertiary : .primary)
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .help(step.date.formatted(date: .abbreviated, time: .standard))
    }
}

/// A section of the Develop sidebar with a VS Code–style header band: click anywhere on the
/// band to minimize or show the section; its buttons sit on the right of the band.
struct SidebarSection<Actions: View, Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isExpanded ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isExpanded {
                    HStack(spacing: 0) { actions() }
                        .buttonStyle(SidebarIconButtonStyle())
                        .opacity(hovering ? 1 : 0.6)
                }
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

            if isExpanded {
                content()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Divider()
        }
        .clipped()
    }
}

/// A clickable sidebar row: highlighted under the pointer, and tinted when current.
struct SidebarRow<Content: View>: View {
    var isCurrent = false
    var onHover: ((Bool) -> Void)?
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isCurrent ? Color.accentColor.opacity(0.2) : Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                onHover?(inside)
            }
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

/// Lightroom Classic's Navigator: the open photo, small. Resting the pointer on a preset shows
/// that preset here, so the big photo only changes when the preset is clicked.
private struct NavigatorView: View {
    @ObservedObject var develop: DevelopController

    var body: some View {
        let previewing = develop.previewingPreset
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.15)
            if let image = (previewing != nil ? develop.navigatorPreview : nil) ?? develop.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
            if let previewing {
                Text(develop.navigatorPreview == nil ? "Previewing \(previewing.name)…" : previewing.name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Rest the pointer on a preset to preview it here; click the preset to apply it")
    }
}
