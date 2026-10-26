import AtelierCore
import SwiftUI

/// The Presets list in the Develop sidebar: click to apply, grouped like Lightroom's.
struct PresetsSection: View {
    @ObservedObject var develop: DevelopController
    @State private var creating = false
    @State private var renaming: DevelopPreset?
    @State private var renameText = ""
    @State private var deleting: DevelopPreset?

    private var groups: [(String, [DevelopPreset])] {
        var result: [(String, [DevelopPreset])] = []
        for preset in develop.presets {
            if let index = result.firstIndex(where: { $0.0 == preset.group }) {
                result[index].1.append(preset)
            } else {
                result.append((preset.group, [preset]))
            }
        }
        return result
    }

    var body: some View {
        Section {
            ForEach(groups, id: \.0) { group in
                DisclosureGroup {
                    ForEach(group.1) { preset in
                        Label(preset.name, systemImage: preset.isBuiltIn ? "wand.and.stars" : "slider.horizontal.3")
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture { develop.applyPreset(preset) }
                            .help("Click to apply: \(preset.parts.map(\.title).sorted().joined(separator: ", "))")
                            .contextMenu {
                                Button("Apply") { develop.applyPreset(preset) }
                                if !preset.isBuiltIn {
                                    Button("Update with Current Settings") { develop.updatePreset(preset) }
                                    Button("Rename…") {
                                        renameText = preset.name
                                        renaming = preset
                                    }
                                    Divider()
                                    Button("Delete…", role: .destructive) { deleting = preset }
                                }
                            }
                    }
                } label: {
                    Label(group.0, systemImage: "folder")
                }
            }
        } header: {
            HStack {
                Text("Presets")
                Spacer()
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Save the current settings as a preset")
                .disabled(develop.assetID == nil)
            }
        }
        .sheet(isPresented: $creating) {
            NewPresetSheet(develop: develop)
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    develop.renamePreset(renaming, to: renameText.trimmingCharacters(in: .whitespaces))
                }
                renaming = nil
            }
        }
        .confirmationDialog("Delete the preset \"\(deleting?.name ?? "")\"?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Preset", role: .destructive) {
                if let deleting { develop.deletePreset(deleting) }
                deleting = nil
            }
        } message: {
            Text("Photos that used it keep their settings.")
        }
    }
}

/// Lightroom's New Develop Preset dialog: a name, a group, and which settings to include.
struct NewPresetSheet: View {
    @ObservedObject var develop: DevelopController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var group = "User Presets"
    @State private var parts = DevelopPreset.Part.defaults

    private var existingGroups: [String] {
        Array(Set(develop.presets.filter { !$0.isBuiltIn }.map(\.group) + ["User Presets"])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Develop Preset").font(.title3.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("Untitled Preset"))
                LabeledContent("Group") {
                    HStack {
                        TextField("Group", text: $group).labelsHidden()
                        Menu {
                            ForEach(existingGroups, id: \.self) { existing in
                                Button(existing) { group = existing }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            GroupBox("Settings to include") {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          spacing: 6) {
                    ForEach(DevelopPreset.Part.allCases, id: \.self) { part in
                        Toggle(part.title, isOn: Binding(get: { parts.contains(part) }, set: { on in
                            if on { parts.insert(part) } else { parts.remove(part) }
                        }))
                    }
                }
                .padding(6)
                HStack {
                    Button("Check All") { parts = Set(DevelopPreset.Part.allCases) }
                    Button("Check None") { parts = [] }
                }
                .controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    let groupName = group.trimmingCharacters(in: .whitespaces)
                    develop.createPreset(name: trimmed.isEmpty ? "Untitled Preset" : trimmed,
                                         group: groupName.isEmpty ? "User Presets" : groupName, parts: parts)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parts.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
