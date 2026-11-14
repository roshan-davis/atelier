import AtelierCore
import SwiftUI

/// "Import Preset: Beach ▾" at the bottom left of the Import dialog (AT-057), as in Lightroom
/// Classic: None, the saved presets, then Save Current Settings as New Preset…, Update, Rename
/// and Delete for the chosen one. Choosing a preset sets the right column at once; a later
/// change shows "(edited)" until it is saved again.
struct ImportPresetMenu: View {
    @ObservedObject var flow: ImportFlow
    @State private var naming: Naming?
    @State private var name = ""
    @State private var replacing: String?
    @State private var problem: String?

    private enum Naming: Identifiable {
        case new
        case rename(ImportPreset)
        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let preset): return preset.id.uuidString
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Import Preset:")
            Menu(flow.importPresetTitle) {
                Button("None") { flow.clearImportPreset() }
                if !flow.importPresets.isEmpty {
                    Divider()
                    ForEach(flow.importPresets) { preset in
                        Button(preset.name) { flow.applyImportPreset(preset) }
                    }
                }
                Divider()
                Button("Save Current Settings as New Preset…") {
                    name = ""
                    naming = .new
                }
                if let chosen = flow.chosenImportPreset {
                    Button("Update Preset \u{201C}\(chosen.name)\u{201D}") { run { try flow.updateChosenImportPreset() } }
                        .disabled(chosen.sameSettings(as: flow.currentImportSettings))
                    Button("Rename Preset \u{201C}\(chosen.name)\u{201D}…") {
                        name = chosen.name
                        naming = .rename(chosen)
                    }
                    Button("Delete Preset \u{201C}\(chosen.name)\u{201D}") { run { try flow.deleteImportPreset(chosen) } }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .foregroundStyle(.primary)
        .onAppear { flow.reloadImportPresets() }
        .alert(naming.map { title($0) } ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Preset Name", text: $name)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(isRename ? "Rename" : "Create") { confirm() }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text(isRename ? "" : "Saves where the photos go, what is applied during import and culling. Not the photos chosen or the import's name.")
        }
        .alert("Replace \u{201C}\(replacing ?? "")\u{201D}?", isPresented: Binding(get: { replacing != nil },
                                                                                 set: { if !$0 { replacing = nil } })) {
            Button("Cancel", role: .cancel) { replacing = nil }
            Button("Replace") {
                let target = replacing ?? ""
                replacing = nil
                run { try flow.saveImportPreset(named: target) }
            }
        } message: {
            Text("An Import Preset with this name already exists. Replacing it saves the current settings under that name.")
        }
        .alert("Couldn\u{2019}t save the Import Preset", isPresented: Binding(get: { problem != nil },
                                                                             set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private var isRename: Bool {
        if case .rename = naming { return true }
        return false
    }

    private func title(_ naming: Naming) -> String {
        switch naming {
        case .new: return "New Import Preset"
        case .rename(let preset): return "Rename \u{201C}\(preset.name)\u{201D}"
        }
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = naming
        naming = nil
        guard !trimmed.isEmpty, let current else { return }
        switch current {
        case .new:
            if flow.importPresets.contains(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
                replacing = trimmed
            } else {
                run { try flow.saveImportPreset(named: trimmed) }
            }
        case .rename(let preset):
            run { try flow.renameImportPreset(preset, to: trimmed) }
        }
    }

    private func run(_ change: () throws -> Void) {
        do { try change() } catch { problem = error.localizedDescription }
    }
}
