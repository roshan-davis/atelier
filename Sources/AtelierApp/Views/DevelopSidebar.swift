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

    var body: some View {
        List {
            PresetsSection(develop: develop)

            Section {
                if develop.history.snapshots.isEmpty {
                    Text("Save the current look to come back to it later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(develop.history.snapshots) { snapshot in
                    Label(snapshot.name, systemImage: "camera.viewfinder")
                        .lineLimit(1)
                        .contentShape(Rectangle())
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
            } header: {
                HStack {
                    Text("Snapshots")
                    Spacer()
                    Button {
                        nameText = Date().formatted(date: .abbreviated, time: .shortened)
                        naming = .newSnapshot
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Create a snapshot of the current settings")
                    .disabled(develop.assetID == nil)
                }
            }

            Section {
                if develop.history.steps.isEmpty {
                    Text("Edits you make appear here. Click one to go back to it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(develop.history.steps.enumerated()).reversed(), id: \.offset) { index, step in
                    HistoryRow(step: step, isCurrent: index == develop.history.position,
                               isUndone: index > develop.history.position)
                        .contentShape(Rectangle())
                        .onTapGesture { develop.go(to: index) }
                }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    Button {
                        develop.clearHistory()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the history, keeping the current settings")
                    .disabled(develop.history.steps.count < 2)
                }
            }
        }
        .listStyle(.sidebar)
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
