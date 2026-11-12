import Foundation

/// A saved HDR look (Rosh, Nov 12, 2026: "Machinery HDR gives great presets on the left panels
/// with thumbnail previews"). Applying one sets every HDR control except Exposure, which belongs
/// to the photo, as in Machinery HDR, Photomatix and HDR Efex Pro, whose presets are looks.
/// A preset saved before the Color sliders existed decodes with them at 0.
public struct HDRPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var group: String
    public var settings: HDRSettings

    public init(id: UUID = UUID(), name: String, group: String = HDRPreset.userGroup, settings: HDRSettings) {
        self.id = id; self.name = name; self.group = group; self.settings = settings
    }

    /// Where the user's own presets go.
    public static let userGroup = "User Presets"

    public var isBuiltIn: Bool { Self.builtInIDs.contains(id) }

    /// `current` with this preset's look: everything but Exposure, with Tone Mapping on.
    public func applied(to current: HDRSettings) -> HDRSettings {
        var result = settings
        result.exposure = current.exposure
        result.toneEnabled = true
        return result
    }

    /// Whether `current` is this preset's look (its Exposure aside).
    public func matches(_ current: HDRSettings) -> Bool { applied(to: current) == current }

    /// The built-in groups, in panel order.
    public static let builtInGroups = ["Natural", "Realistic", "Dramatic", "Architecture", "Landscape", "Fusion"]

    /// The built-in presets. Their ids are fixed so favorites and the selected outline survive
    /// relaunches. Chosen on contact sheets of two test photos (a forest with light shafts, and the
    /// same with its highlights pushed 2 stops over white) so each one looks different.
    public static let builtIn: [HDRPreset] = {
        func make(_ number: Int, _ group: String, _ name: String, _ edit: (inout HDRSettings) -> Void) -> HDRPreset {
            var settings = HDRSettings()
            edit(&settings)
            let id = UUID(uuidString: String(format: "6E3D0000-0000-4000-8000-%012ld", number))!
            return HDRPreset(id: id, name: name, group: group, settings: settings)
        }
        func look(_ s: inout HDRSettings, range: Float, micro: Float, detail: Float,
                  highlights: Float = 0, shadows: Float = 0) {
            s.compression = range; s.microcontrast = micro; s.detail = detail
            s.highlights = highlights; s.shadows = shadows
        }
        func fusion(_ s: inout HDRSettings, spacing: Float) { s.method = .fusion; s.fusionSpacing = spacing }
        func color(_ s: inout HDRSettings, temperature: Float = 0, vibrance: Float = 0, saturation: Float = 0) {
            s.temperature = temperature; s.vibrance = vibrance; s.saturation = saturation
        }
        return [
            make(1, "Natural", "Natural") { _ in },
            make(2, "Natural", "Soft") { look(&$0, range: 0.5, micro: 0.3, detail: 0.15, highlights: -0.2) },
            make(3, "Natural", "Bright") {
                look(&$0, range: 0.7, micro: 0.5, detail: 0.3, highlights: -0.2, shadows: 0.4); color(&$0, vibrance: 0.2)
            },
            make(4, "Realistic", "Balanced") {
                look(&$0, range: 0.8, micro: 0.45, detail: 0.3, highlights: -0.3, shadows: 0.2); color(&$0, vibrance: 0.1)
            },
            make(5, "Realistic", "Open Shadows") { look(&$0, range: 0.85, micro: 0.5, detail: 0.3, shadows: 0.6) },
            make(6, "Realistic", "Window Pull") { look(&$0, range: 0.95, micro: 0.35, detail: 0.25, highlights: -0.6, shadows: 0.3) },
            make(7, "Dramatic", "Dramatic") {
                look(&$0, range: 1, micro: 1, detail: 0.7, highlights: -0.4, shadows: 0.3); color(&$0, saturation: -0.25)
            },
            make(8, "Dramatic", "Gritty") { look(&$0, range: 0.9, micro: 0.8, detail: 1, shadows: 0.1); color(&$0, saturation: -0.4) },
            make(9, "Dramatic", "Dark Drama") {
                look(&$0, range: 0.9, micro: 0.9, detail: 0.6, highlights: -0.5, shadows: -0.3)
                color(&$0, temperature: -0.1, saturation: -0.35)
            },
            make(10, "Architecture", "Crisp Lines") { look(&$0, range: 0.85, micro: 0.7, detail: 0.6, highlights: -0.4, shadows: 0.2) },
            make(11, "Architecture", "Even Interior") {
                fusion(&$0, spacing: 2.5); look(&$0, range: 0.9, micro: 0.3, detail: 0.2, highlights: -0.3)
                color(&$0, temperature: 0.05)
            },
            make(12, "Landscape", "Landscape") {
                look(&$0, range: 0.8, micro: 0.7, detail: 0.45, highlights: -0.5, shadows: 0.25); color(&$0, vibrance: 0.35)
            },
            make(13, "Landscape", "Sky Recovery") {
                look(&$0, range: 0.9, micro: 0.5, detail: 0.35, highlights: -0.8, shadows: 0.1)
                color(&$0, temperature: -0.05, vibrance: 0.2)
            },
            make(14, "Fusion", "Fusion Natural") { fusion(&$0, spacing: 2); look(&$0, range: 0.65, micro: 0.4, detail: 0.3) },
            make(15, "Fusion", "Fusion Soft") {
                fusion(&$0, spacing: 1.5); look(&$0, range: 0.8, micro: 0.2, detail: 0.1); color(&$0, saturation: -0.1)
            },
            make(16, "Fusion", "Fusion Wide") { fusion(&$0, spacing: 3); look(&$0, range: 1, micro: 0.5, detail: 0.35) },
            make(17, "Fusion", "Painterly") {
                fusion(&$0, spacing: 3); look(&$0, range: 1, micro: 1, detail: 1); color(&$0, vibrance: 0.3, saturation: 0.3)
            },
        ]
    }()

    static let builtInIDs = Set(builtIn.map(\.id))
}

/// The user's HDR presets, in one JSON file outside the catalog so every catalog shares them
/// (as Develop's `PresetStore`).
public final class HDRPresetStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier", isDirectory: true)
            .appendingPathComponent("HDR Presets.json")
    }

    /// The user's presets by name, then the built-in ones in their fixed order.
    public func all() -> [HDRPreset] {
        userPresets().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } + HDRPreset.builtIn
    }

    public func userPresets() -> [HDRPreset] { (try? load()) ?? [] }

    /// Adds or replaces a user preset.
    public func save(_ preset: HDRPreset) throws {
        guard !preset.isBuiltIn else { return }
        try write(try load().filter { $0.id != preset.id } + [preset])
    }

    public func rename(_ id: UUID, to name: String) throws {
        try write(try load().map { preset in
            var preset = preset
            if preset.id == id { preset.name = name }
            return preset
        })
    }

    public func delete(_ id: UUID) throws {
        try write(try load().filter { $0.id != id })
    }

    /// The saved presets; one that can't be read (a newer setting, a damaged entry) is skipped.
    /// Throws when the file exists but isn't a preset list, so saving never overwrites it.
    private func load() throws -> [HDRPreset] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.preset)
    }

    private struct Lossy: Decodable {
        let preset: HDRPreset?
        init(from decoder: Decoder) throws { preset = try? HDRPreset(from: decoder) }
    }

    private func write(_ presets: [HDRPreset]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: fileURL, options: .atomic)
    }
}
