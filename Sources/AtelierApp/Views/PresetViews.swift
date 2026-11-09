import AtelierCore
import SwiftUI

/// One collapsible group in the Presets panel.
private struct PresetGroup: Identifiable {
    let name: String
    let isBuiltIn: Bool
    var presets: [DevelopPreset]
    /// The Recent group: the last presets applied, from any group.
    var isRecent = false

    static let recentName = "Recent"

    /// The user's groups can't take a built-in pack's name, but older preset files might have.
    var id: String { isRecent ? "recent" : (isBuiltIn ? "pack:" : "user:") + name }
    var isDefault: Bool { !isBuiltIn && !isRecent && name == DevelopPreset.defaultGroup }
}

/// The Presets list in the Develop sidebar, grouped like Lightroom's: the user's groups first,
/// then the built-in packs, under a Recent group of the presets applied last. Click to apply, rest
/// the pointer on one to preview it in the Navigator.
struct PresetsSection: View {
    @ObservedObject var develop: DevelopController
    @Binding var isExpanded: Bool
    @State private var search = ""
    /// Groups opened or closed away from their default (the user's open, built-in packs closed).
    @AppStorage("presets.toggledGroups") private var toggledList = ""
    @State private var hoverTask: Task<Void, Never>?
    @State private var newPresetGroup: String?
    @State private var updating: DevelopPreset?
    @State private var naming: NameRequest?
    @State private var nameText = ""
    @State private var deleting: DevelopPreset?
    @State private var deletingGroup: PresetGroup?

    private enum NameRequest {
        case renamePreset(DevelopPreset)
        case renameGroup(String)
        case moveToNewGroup(DevelopPreset)

        var title: String {
            switch self {
            case .renamePreset: return "Rename Preset"
            case .renameGroup: return "Rename Group"
            case .moveToNewGroup: return "New Group"
            }
        }

        var action: String {
            switch self {
            case .renamePreset, .renameGroup: return "Rename"
            case .moveToNewGroup: return "Move"
            }
        }

        var namesGroup: Bool {
            if case .renamePreset = self { return false }
            return true
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var groups: [PresetGroup] { groups(matching: query) }

    private func groups(matching query: String) -> [PresetGroup] {
        var result: [PresetGroup] = []
        // Recent is a shortcut, so a search (which already finds every preset) leaves it out.
        let recent = develop.recentPresets
        if query.isEmpty, !recent.isEmpty {
            result.append(PresetGroup(name: PresetGroup.recentName, isBuiltIn: false, presets: recent, isRecent: true))
        }
        for preset in develop.visiblePresets where query.isEmpty || preset.name.localizedCaseInsensitiveContains(query) {
            if let index = result.firstIndex(where: { !$0.isRecent && $0.name == preset.group && $0.isBuiltIn == preset.isBuiltIn }) {
                result[index].presets.append(preset)
            } else {
                result.append(PresetGroup(name: preset.group, isBuiltIn: preset.isBuiltIn, presets: [preset]))
            }
        }
        return result
    }

    private var toggled: Set<String> {
        Set(toggledList.split(separator: "\n").map(String.init))
    }

    private func isExpanded(_ group: PresetGroup) -> Binding<Bool> {
        Binding(get: {
            // A search opens every group with a match. Otherwise a pack is open only when toggled,
            // and one of the user's groups only when not.
            !query.isEmpty || (group.isBuiltIn == toggled.contains(group.id))
        }, set: { open in
            guard query.isEmpty else { return }
            var set = toggled
            if open == group.isBuiltIn { set.insert(group.id) } else { set.remove(group.id) }
            toggledList = set.sorted().joined(separator: "\n")
        })
    }

    /// Closes every group, like VS Code's Collapse Folders.
    private func collapseAllGroups() {
        // The user's groups are open unless toggled; the packs are closed unless toggled.
        let userGroups = groups(matching: "").filter { !$0.isBuiltIn }.map(\.id)
        withAnimation(.easeInOut(duration: 0.15)) {
            search = ""
            toggledList = userGroups.sorted().joined(separator: "\n")
        }
    }

    var body: some View {
        let _ = DevelopTrace.body("PresetsSection")
        SidebarSection(title: "Presets", isExpanded: $isExpanded) {
            Button {
                develop.showingNewPreset = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Create Preset from the current settings (⇧⌘N)")
            .disabled(develop.assetID == nil)
            Button(action: collapseAllGroups) {
                Image(systemName: "rectangle.compress.vertical")
            }
            .help("Collapse All Groups")
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if let amount = develop.presetAmount {
                    AmountRow(develop: develop, amount: amount)
                        .padding(.bottom, 4)
                }
                TextField("Search Presets", text: $search, prompt: Text("Search Presets"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .labelsHidden()
                    .padding(.bottom, 4)
                if groups.isEmpty, !query.isEmpty {
                    Text("No presets named \"\(query)\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    let open = isExpanded(group)
                    groupLabel(group, open: open)
                    if open.wrappedValue {
                        ForEach(group.presets) { preset in
                            row(preset, inRecent: group.isRecent)
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            develop.previewPreset(nil)
        }
        .sheet(isPresented: $develop.showingNewPreset, onDismiss: { newPresetGroup = nil }) {
            PresetSheet(develop: develop, mode: .create(group: newPresetGroup))
        }
        .sheet(item: $updating) { preset in
            PresetSheet(develop: develop, mode: .update(preset))
        }
        .sheet(isPresented: $develop.showingManagePresets) {
            ManagePresetsSheet(develop: develop)
        }
        .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(naming?.action ?? "OK") { commitName() }
                .disabled(!isValidName)
        } message: {
            if naming?.namesGroup == true {
                Text("Built-in pack names (\(DevelopPreset.builtInGroups.joined(separator: ", "))) can't be used.")
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
        .confirmationDialog(deleteGroupTitle,
                            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
            Button("Delete Group", role: .destructive) {
                if let deletingGroup { develop.deletePresetGroup(deletingGroup.name) }
                deletingGroup = nil
            }
        } message: {
            Text("This can't be undone. Photos that used these presets keep their settings.")
        }
    }

    private var deleteGroupTitle: String {
        guard let group = deletingGroup else { return "" }
        let count = develop.presets.filter { !$0.isBuiltIn && $0.group == group.name }.count
        return "Delete the group \"\(group.name)\" and its \(count) preset\(count == 1 ? "" : "s")?"
    }

    // MARK: Rows

    private func row(_ preset: DevelopPreset, inRecent: Bool = false) -> some View {
        // A button rather than a tap gesture: a click on the row always applies the preset.
        Button {
            apply(preset)
        } label: {
            SidebarRow(isCurrent: develop.presetAmount?.preset.id == preset.id, onHover: { hover(preset, $0) }) {
                Label(preset.name, systemImage: preset.isBuiltIn ? "wand.and.stars" : "slider.horizontal.3")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if preset.isBuiltIn {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(develop.assetID == nil)
        .help((inRecent ? "From \(preset.group). " : "")
            + "Click to apply. Includes \(DevelopPreset.Part.allCases.filter { preset.parts.contains($0) }.map(\.title).joined(separator: ", ")).")
        .contextMenu {
            if inRecent {
                Button("Remove from Recent") { develop.removeFromRecent(preset) }
                Divider()
            }
            presetMenu(preset)
        }
    }

    private func apply(_ preset: DevelopPreset) {
        hoverTask?.cancel()
        develop.applyPreset(preset)
    }

    @ViewBuilder
    private func presetMenu(_ preset: DevelopPreset) -> some View {
        Button("Apply") { apply(preset) }
            .disabled(develop.assetID == nil)
        if preset.isBuiltIn {
            Button("Duplicate to User Presets") { develop.duplicatePreset(preset) }
        } else {
            Button("Update with Current Settings…") { updating = preset }
                .disabled(develop.assetID == nil)
            Button("Rename…") {
                nameText = preset.name
                naming = .renamePreset(preset)
            }
            Menu("Move to Group") {
                ForEach(develop.userPresetGroups, id: \.self) { group in
                    Button(group) { develop.movePreset(preset, to: group) }
                        .disabled(group == preset.group)
                }
                Divider()
                Button("New Group…") {
                    nameText = ""
                    naming = .moveToNewGroup(preset)
                }
            }
            Button("Duplicate") { develop.duplicatePreset(preset) }
            Button("Show in Finder") { develop.showPresetsInFinder() }
            Divider()
            Button("Delete…", role: .destructive) { deleting = preset }
        }
    }

    private func groupLabel(_ group: PresetGroup, open: Binding<Bool>) -> some View {
        SidebarRow {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                .frame(width: 10)
            Label(group.name, systemImage: group.isRecent ? "clock" : group.isBuiltIn ? "shippingbox" : "folder")
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(group.presets.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { open.wrappedValue.toggle() }
        }
        .contextMenu { groupMenu(group) }
    }

    @ViewBuilder
    private func groupMenu(_ group: PresetGroup) -> some View {
        if group.isRecent {
            Button("Clear Recent") { develop.clearRecentPresets() }
        } else if group.isBuiltIn {
            Button("Hide Group") { _ = develop.hiddenPresetGroups.insert(group.name) }
            Button("Manage Presets…") { develop.showingManagePresets = true }
        } else {
            Button("Create Preset in This Group…") {
                newPresetGroup = group.name
                develop.showingNewPreset = true
            }
            .disabled(develop.assetID == nil)
            if !group.isDefault {
                Button("Rename Group…") {
                    nameText = group.name
                    naming = .renameGroup(group.name)
                }
                Divider()
                Button("Delete Group…", role: .destructive) { deletingGroup = group }
            }
        }
    }

    // MARK: Hover preview

    private func hover(_ preset: DevelopPreset, _ inside: Bool) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            // A short rest before previewing, so sweeping across the list doesn't render each one;
            // a short grace on leaving, so moving to the next preset doesn't flash the photo back.
            try? await Task.sleep(for: .milliseconds(inside ? 120 : 150))
            guard !Task.isCancelled else { return }
            if inside {
                // The preset just applied is already on the photo.
                guard develop.presetAmount?.preset.id != preset.id else { return }
                develop.previewPreset(preset)
            } else if develop.previewingPreset?.id == preset.id {
                develop.previewPreset(nil)
            }
        }
    }

    // MARK: Naming

    private var isValidName: Bool {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return naming?.namesGroup != true || !DevelopPreset.isBuiltInGroup(name)
    }

    private func commitName() {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        guard isValidName, let request = naming else { return }
        switch request {
        case .renamePreset(let preset): develop.renamePreset(preset, to: name)
        case .renameGroup(let group): develop.renamePresetGroup(group, to: name)
        case .moveToNewGroup(let preset): develop.movePreset(preset, to: name)
        }
        naming = nil
    }
}

/// Lightroom Classic's preset Amount: scales the last clicked preset from 0 to 200%.
private struct AmountRow: View {
    @ObservedObject var develop: DevelopController
    let amount: DevelopController.PresetAmount

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(amount.preset.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text("Amount")
                    .frame(width: 56, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { develop.setPresetAmount(100) }
                    .help("Double-click to reset to 100%")
                DevelopSlider(value: Binding(get: { develop.presetAmount?.amount ?? 100 },
                                             set: { develop.setPresetAmount($0) }),
                              range: 0...200, step: 1, origin: 100, gradient: nil)
                Text("\(Int(amount.amount))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .font(.callout)
    }
}

/// Lightroom's Create Preset dialog: a name, a group (or a new one), and which settings to
/// include. Also used for Update with Current Settings, which keeps the name and group.
struct PresetSheet: View {
    enum Mode {
        case create(group: String?)
        case update(DevelopPreset)
    }

    @ObservedObject var develop: DevelopController
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var groupChoice: String
    @State private var newGroupName = ""
    @State private var parts: Set<DevelopPreset.Part>
    @State private var replacing: DevelopPreset?

    private static let newGroupTag = "\u{1}new-group"
    private static let lastPartsKey = "presets.lastParts"

    init(develop: DevelopController, mode: Mode) {
        _develop = ObservedObject(wrappedValue: develop)
        self.mode = mode
        switch mode {
        case .create(let group):
            _name = State(initialValue: "")
            _groupChoice = State(initialValue: group ?? DevelopPreset.defaultGroup)
            // The dialog remembers the last choice of settings, as Lightroom does.
            let saved = UserDefaults.standard.string(forKey: Self.lastPartsKey).map {
                Set($0.split(separator: ",").compactMap { DevelopPreset.Part(rawValue: String($0)) })
            }
            _parts = State(initialValue: saved ?? DevelopPreset.Part.defaults)
        case .update(let preset):
            _name = State(initialValue: preset.name)
            _groupChoice = State(initialValue: preset.group)
            _parts = State(initialValue: preset.parts)
        }
    }

    private var isUpdate: Bool {
        if case .update = mode { return true }
        return false
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var group: String {
        groupChoice == Self.newGroupTag ? newGroupName.trimmingCharacters(in: .whitespaces) : groupChoice
    }

    private var groupProblem: String? {
        guard groupChoice == Self.newGroupTag else { return nil }
        if group.isEmpty { return "Name the new group." }
        if DevelopPreset.isBuiltInGroup(group) { return "\"\(group)\" is a built-in pack; choose another name." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isUpdate ? "Update Preset \"\(trimmedName)\"" : "Create Preset").font(.title3.bold())
            if !isUpdate {
                Form {
                    TextField("Preset Name", text: $name, prompt: Text("Untitled Preset"))
                    Picker("Group", selection: $groupChoice) {
                        ForEach(develop.userPresetGroups, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("New Group…").tag(Self.newGroupTag)
                    }
                    if groupChoice == Self.newGroupTag {
                        TextField("Group Name", text: $newGroupName, prompt: Text("e.g. Weddings"))
                        if let groupProblem, !newGroupName.isEmpty {
                            Text(groupProblem)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            } else {
                Text("Choose which of this photo's settings the preset carries from now on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            GroupBox("Settings") {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(DevelopPreset.Part.allCases, id: \.self) { part in
                        Toggle(isOn: Binding(get: { parts.contains(part) }, set: { on in
                            if on { parts.insert(part) } else { parts.remove(part) }
                        })) {
                            HStack(spacing: 3) {
                                Text(part.title)
                                if !part.isChanged(in: develop.settings) {
                                    Text("(no change)").foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)
                        }
                        .help(part.detail ?? part.title)
                    }
                }
                .padding(6)
                HStack {
                    Button("Check All") { parts = Set(DevelopPreset.Part.allCases) }
                    Button("Check None") { parts = [] }
                    Spacer()
                }
                .controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isUpdate ? "Update" : "Create") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || parts.isEmpty || groupProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .confirmationDialog("A preset named \"\(trimmedName)\" is already in \(group).",
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button("Replace") {
                save(replacing: replacing)
            }
            Button("Cancel", role: .cancel) { replacing = nil }
        } message: {
            Text("Replacing it updates the preset with these settings.")
        }
    }

    private func commit() {
        switch mode {
        case .update(let preset):
            develop.updatePreset(preset, parts: parts)
            dismiss()
        case .create:
            if let existing = develop.userPreset(named: trimmedName, in: group) {
                replacing = existing
            } else {
                save(replacing: nil)
            }
        }
    }

    private func save(replacing existing: DevelopPreset?) {
        UserDefaults.standard.set(DevelopPreset.Part.allCases.filter { parts.contains($0) }.map(\.rawValue)
            .joined(separator: ","), forKey: Self.lastPartsKey)
        develop.createPreset(name: trimmedName, group: group, parts: parts, replacing: existing)
        replacing = nil
        dismiss()
    }
}

/// Develop > Manage Presets…: which built-in packs are listed.
struct ManagePresetsSheet: View {
    @ObservedObject var develop: DevelopController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage Presets").font(.title3.bold())
            Text("Choose which built-in packs appear in the Presets panel, the photo menu and the Import dialog. Hidden presets still work on photos that use them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(DevelopPreset.builtInGroups, id: \.self) { group in
                        Toggle(isOn: Binding(get: { !develop.hiddenPresetGroups.contains(group) }, set: { show in
                            if show { develop.hiddenPresetGroups.remove(group) } else { develop.hiddenPresetGroups.insert(group) }
                        })) {
                            HStack {
                                Text(group)
                                Spacer()
                                Text("\(DevelopPreset.builtIn.filter { $0.group == group }.count) presets")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Show All") { develop.hiddenPresetGroups = [] }
                    .disabled(develop.hiddenPresetGroups.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
