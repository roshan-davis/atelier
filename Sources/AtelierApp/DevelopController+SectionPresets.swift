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
        if kind == .toneCurve { showCurves(of: preset) }
    }

    /// After a Tone Curve preset, the panel shows what it did (Rosh, Nov 13, 2026: Negative,
    /// made with the Red, Green and Blue curves, left the RGB view a straight line): the Point
    /// view on the RGB curve if the preset bends it, else on its first color channel, with Show
    /// All Curves on when it bends more than one channel. A preset of region sliders alone, or
    /// Linear, leaves the view as it is.
    private func showCurves(of preset: DevelopPreset) {
        let bent = SectionPresetKind.bentChannels(of: preset)
        guard let first = bent.first else { return }
        let defaults = UserDefaults.standard
        defaults.set("point", forKey: Self.curveModeKey)
        defaults.set(first.rawValue, forKey: Self.curveChannelKey)
        if bent.count > 1 { defaults.set(true, forKey: Self.curveShowAllKey) }
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
