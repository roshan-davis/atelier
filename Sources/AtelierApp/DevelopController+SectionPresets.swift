import AppKit
import AtelierCore

/// The Tone Curve and Color Grading panels' Preset menus: presets that change only that panel.
extension DevelopController {
    /// Built-in presets in their groups, then the user's own (in name order).
    func sectionPresets(_ kind: SectionPresetKind) -> [DevelopPreset] {
        kind.builtIn + (userSectionPresets[kind] ?? [])
    }

    /// The preset the panel matches, if any. The user's presets come first, so a saved copy of
    /// a built-in look shows the user's name.
    func sectionPresetMatch(_ kind: SectionPresetKind) -> DevelopPreset? {
        kind.matching(settings, in: (userSectionPresets[kind] ?? []) + kind.builtIn)
    }

    /// The name the panel's menu shows: the preset the panel matches, else "Custom".
    func sectionPresetTitle(_ kind: SectionPresetKind) -> String {
        sectionPresetMatch(kind)?.name ?? "Custom"
    }

    /// Applies the preset to the open photo: only its panel changes, as one history step.
    func applySectionPreset(_ preset: DevelopPreset, kind: SectionPresetKind) {
        guard assetID != nil else { return }
        previewPreset(nil)
        apply(preset.applied(to: settings), onto: nil, step: "\(kind.title) Preset: \(preset.name)")
        // Saved and in the history at once, as a Develop preset is.
        flushSave()
    }

    /// Saves the panel's current settings as a preset; a preset of the same name is replaced.
    func saveSectionPreset(_ kind: SectionPresetKind, named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let existing = userSectionPreset(kind, named: trimmed)
        let preset = kind.preset(named: trimmed, from: settings, id: existing?.id ?? UUID())
        sectionPresetFileChange(kind) { try $0.save(preset) }
    }

    func deleteSectionPreset(_ preset: DevelopPreset, kind: SectionPresetKind) {
        if sectionPresetFileChange(kind, { try $0.delete(preset.id) }) { DeleteFeedback.play(.remove) }
    }

    /// The user's preset named `name` (ignoring case), if there is one.
    func userSectionPreset(_ kind: SectionPresetKind, named name: String) -> DevelopPreset? {
        userSectionPresets[kind]?.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether the change was saved.
    @discardableResult
    private func sectionPresetFileChange(_ kind: SectionPresetKind, _ change: (PresetStore) throws -> Void) -> Bool {
        let store = PresetStore(section: kind)
        defer { userSectionPresets[kind] = store.userPresets() }
        do {
            try change(store)
            return true
        } catch {
            reportError("Could not save \(kind.title) presets: \(error.localizedDescription)")
            return false
        }
    }
}
