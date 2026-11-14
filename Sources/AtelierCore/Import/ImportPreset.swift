import Foundation

/// A saved set of Import dialog settings (AT-057), picked from the Import Preset menu at the
/// bottom of the dialog, as in Lightroom Classic. It holds the right column's choices: where the
/// photos go (left in place or copied, and the library folder), what is applied during import
/// (the Develop preset, then a Tone Curve preset and a Color Grading preset, and keywords) and
/// whether to cull first. Not the sources or the import's name, which change every time.
///
/// Presets are named by id; a preset that is gone (deleted, or a retired built-in) is left out
/// when the Import Preset is used, and the dialog says so. Every field decodes with a default, so
/// a file from an older Atelier still loads.
public struct ImportPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Copy into the library folder (true) or leave files where they are.
    public var copyFiles: Bool
    /// The library folder for copies; nil keeps the dialog's current one.
    public var destinationPath: String?
    /// Develop preset applied first, then the Tone Curve and Color Grading presets (AT-057).
    public var developPresetID: UUID?
    public var toneCurvePresetID: UUID?
    public var colorGradingPresetID: UUID?
    /// Comma-separated, as typed in the dialog.
    public var keywords: String
    public var cullFirst: Bool

    public init(id: UUID = UUID(), name: String, copyFiles: Bool = false, destinationPath: String? = nil,
                developPresetID: UUID? = nil, toneCurvePresetID: UUID? = nil, colorGradingPresetID: UUID? = nil,
                keywords: String = "", cullFirst: Bool = false) {
        self.id = id
        self.name = name
        self.copyFiles = copyFiles
        self.destinationPath = destinationPath
        self.developPresetID = developPresetID
        self.toneCurvePresetID = toneCurvePresetID
        self.colorGradingPresetID = colorGradingPresetID
        self.keywords = keywords
        self.cullFirst = cullFirst
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, copyFiles, destinationPath, developPresetID, toneCurvePresetID, colorGradingPresetID
        case keywords, cullFirst
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        copyFiles = try c.decodeIfPresent(Bool.self, forKey: .copyFiles) ?? false
        destinationPath = try c.decodeIfPresent(String.self, forKey: .destinationPath)
        developPresetID = try c.decodeIfPresent(UUID.self, forKey: .developPresetID)
        toneCurvePresetID = try c.decodeIfPresent(UUID.self, forKey: .toneCurvePresetID)
        colorGradingPresetID = try c.decodeIfPresent(UUID.self, forKey: .colorGradingPresetID)
        keywords = try c.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        cullFirst = try c.decodeIfPresent(Bool.self, forKey: .cullFirst) ?? false
    }

    /// The same choices, ignoring the name and id: the dialog shows a preset's name only while
    /// its settings still match ("Beach (edited)" otherwise).
    public func sameSettings(as other: ImportPreset) -> Bool {
        var a = self, b = other
        a.id = b.id
        a.name = b.name
        return a == b
    }
}

/// The user's Import Presets, in "Import Presets.json" beside Presets.json, in name order.
public final class ImportPresetStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = ImportPresetStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier", isDirectory: true)
            .appendingPathComponent("Import Presets.json")
    }

    public func all() -> [ImportPreset] {
        (try? load()) ?? []
    }

    /// Adds a preset, or replaces the one with the same id or, failing that, the same name
    /// (Lightroom asks before replacing; the dialog does too).
    public func save(_ preset: ImportPreset) throws {
        let kept = try load().filter {
            $0.id != preset.id && $0.name.compare(preset.name, options: .caseInsensitive) != .orderedSame
        }
        try write(kept + [preset])
    }

    public func delete(_ id: UUID) throws {
        try write(try load().filter { $0.id != id })
    }

    public func rename(_ id: UUID, to name: String) throws {
        try write(try load().map { preset in
            var preset = preset
            if preset.id == id { preset.name = name }
            return preset
        })
    }

    /// Throws when the file exists but isn't a preset list, so saving never overwrites presets
    /// it couldn't read; a single unreadable preset is skipped.
    private func load() throws -> [ImportPreset] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.preset)
    }

    private struct Lossy: Decodable {
        let preset: ImportPreset?
        init(from decoder: Decoder) throws { preset = try? ImportPreset(from: decoder) }
    }

    private func write(_ presets: [ImportPreset]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sorted = presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try encoder.encode(sorted).write(to: fileURL, options: .atomic)
    }
}
