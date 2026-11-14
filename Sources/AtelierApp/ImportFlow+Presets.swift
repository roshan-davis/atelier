import AtelierCore
import Foundation

/// Import Presets (AT-057): the Import dialog's settings saved under a name, picked from the
/// Import Preset menu at the bottom of the dialog, as in Lightroom Classic.
extension ImportFlow {
    static let importPresetStore = ImportPresetStore()
    private static let chosenKey = "import.preset"

    /// The dialog's settings now, as an unnamed Import Preset.
    var currentImportSettings: ImportPreset {
        ImportPreset(name: "", copyFiles: copyFiles, destinationPath: copyFiles ? destinationPath : nil,
                     developPresetID: UUID(uuidString: presetID), toneCurvePresetID: UUID(uuidString: toneCurvePresetID),
                     colorGradingPresetID: UUID(uuidString: colorGradingPresetID), keywords: keywords,
                     cullFirst: cullFirst)
    }

    /// The Import Preset last chosen, if it still exists.
    var chosenImportPreset: ImportPreset? {
        guard let id = UserDefaults.standard.string(forKey: Self.chosenKey).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return importPresets.first { $0.id == id }
    }

    /// "None", the chosen preset's name, or "Beach (edited)" once a setting differs from it.
    var importPresetTitle: String {
        guard let chosen = chosenImportPreset else { return "None" }
        return chosen.sameSettings(as: currentImportSettings) ? chosen.name : "\(chosen.name) (edited)"
    }

    func reloadImportPresets() {
        importPresets = Self.importPresetStore.all()
    }

    /// Sets the dialog to the preset. A Develop, Tone Curve or Color Grading preset it names that
    /// no longer exists is left at None, and `importPresetNote` says which.
    func applyImportPreset(_ preset: ImportPreset) {
        objectWillChange.send()
        UserDefaults.standard.set(preset.id.uuidString, forKey: Self.chosenKey)
        copyFiles = preset.copyFiles
        if let path = preset.destinationPath { destinationPath = path }
        keywords = preset.keywords
        cullFirst = preset.cullFirst
        var missing: [String] = []
        if let id = preset.developPresetID {
            let exists = model?.develop.presets.contains { $0.id == id } == true
                || DevelopPreset.retiredImportPreset(id: id.uuidString) != nil
            presetID = exists ? id.uuidString : ""
            if !exists { missing.append("Develop") }
        } else {
            presetID = ""
        }
        func section(_ kind: SectionPresetKind, _ id: UUID?) -> String {
            guard let id else { return "" }
            if sectionPreset(kind, id: id.uuidString) != nil { return id.uuidString }
            missing.append(kind.title)
            return ""
        }
        toneCurvePresetID = section(.toneCurve, preset.toneCurvePresetID)
        colorGradingPresetID = section(.colorGrading, preset.colorGradingPresetID)
        importPresetNote = missing.isEmpty ? nil
            : "\u{201C}\(preset.name)\u{201D} named a \(missing.joined(separator: " and ")) preset that no longer exists, so it is set to None."
    }

    /// Import Preset > None: the settings stay as they are; only the name goes.
    func clearImportPreset() {
        objectWillChange.send()
        UserDefaults.standard.removeObject(forKey: Self.chosenKey)
        importPresetNote = nil
    }

    /// Saves the dialog's settings; a preset with the same name is replaced (the dialog asks first).
    func saveImportPreset(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var preset = currentImportSettings
        preset.name = trimmed
        if let existing = importPresets.first(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            preset.id = existing.id
        }
        try Self.importPresetStore.save(preset)
        reloadImportPresets()
        UserDefaults.standard.set(preset.id.uuidString, forKey: Self.chosenKey)
        importPresetNote = nil
    }

    /// Saves the dialog's settings into the chosen preset (Update Preset "Beach").
    func updateChosenImportPreset() throws {
        guard let chosen = chosenImportPreset else { return }
        try saveImportPreset(named: chosen.name)
    }

    func renameImportPreset(_ preset: ImportPreset, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try Self.importPresetStore.rename(preset.id, to: trimmed)
        reloadImportPresets()
    }

    func deleteImportPreset(_ preset: ImportPreset) throws {
        try Self.importPresetStore.delete(preset.id)
        if chosenImportPreset?.id == preset.id { clearImportPreset() }
        reloadImportPresets()
        DeleteFeedback.play(.remove)
    }
}
