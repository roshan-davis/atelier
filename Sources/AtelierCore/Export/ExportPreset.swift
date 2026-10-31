import Foundation

/// A named set of export choices: format, size, color, sharpening, metadata and watermark.
/// The folder is not part of a preset; the dialog keeps the last one used.
public struct ExportPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var format: ExportFormat
    public var quality: Double
    public var longEdge: Int?
    public var colorSpace: ExportColorSpace
    public var metadata: ExportMetadata
    public var sharpening: ExportSharpening
    public var watermark: ExportWatermark?

    public init(name: String, settings: ExportSettings, id: UUID = UUID()) {
        self.id = id
        self.name = name
        format = settings.format
        quality = settings.quality
        longEdge = settings.longEdge
        colorSpace = settings.colorSpace
        metadata = settings.metadata
        sharpening = settings.sharpening
        watermark = settings.watermark
    }

    /// Sets every choice the preset holds; the destination is left as it is.
    public func apply(to settings: inout ExportSettings) {
        settings.format = format
        settings.quality = quality
        settings.longEdge = longEdge
        settings.colorSpace = colorSpace
        settings.metadata = metadata
        settings.sharpening = sharpening
        settings.watermark = watermark
    }

    /// True when exporting with `settings` would give what this preset gives. Quality only
    /// counts for formats that have it.
    public func matches(_ settings: ExportSettings) -> Bool {
        var applied = settings
        apply(to: &applied)
        if !format.hasQuality { applied.quality = settings.quality }
        return applied == settings
    }

    public var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

    /// One line for the preset's tooltip, e.g. "JPEG 85, 2048 px, sRGB, sharpened, no location".
    public var summary: String {
        var parts = [format.hasQuality ? "\(format.label) \(Int((quality * 100).rounded()))" : format.label]
        parts.append(longEdge.map { "\($0) px" } ?? "full size")
        parts.append(colorSpace == .sRGB ? "sRGB" : colorSpace.label)
        if sharpening == .screen { parts.append("sharpened") }
        switch metadata {
        case .all: parts.append("all metadata")
        case .allExceptLocation: parts.append("no location")
        case .none: parts.append("no metadata")
        }
        if let watermark, watermark.hasContent { parts.append("watermark") }
        return parts.joined(separator: ", ")
    }

    // MARK: Built-in

    public static let website: ExportPreset = {
        var settings = ExportSettings(destination: URL(fileURLWithPath: "/"))
        settings.format = .jpeg
        settings.quality = 0.85
        settings.longEdge = 2048
        settings.colorSpace = .sRGB
        settings.sharpening = .screen
        settings.metadata = .allExceptLocation
        return ExportPreset(name: "Website", settings: settings, id: UUID(uuidString: "6C1E7A52-0D6B-4C7E-9A61-2F1B7E0A0001")!)
    }()

    public static let fullSizeJPEG: ExportPreset = {
        var settings = ExportSettings(destination: URL(fileURLWithPath: "/"))
        settings.format = .jpeg
        settings.quality = 0.95
        settings.longEdge = nil
        settings.colorSpace = .sRGB
        settings.sharpening = .none
        settings.metadata = .all
        return ExportPreset(name: "Full-Size JPEG", settings: settings, id: UUID(uuidString: "6C1E7A52-0D6B-4C7E-9A61-2F1B7E0A0002")!)
    }()

    public static let fullSizeTIFF: ExportPreset = {
        var settings = ExportSettings(destination: URL(fileURLWithPath: "/"))
        settings.format = .tiff
        settings.longEdge = nil
        settings.colorSpace = .adobeRGB
        settings.sharpening = .none
        settings.metadata = .all
        return ExportPreset(name: "Full-Size TIFF", settings: settings, id: UUID(uuidString: "6C1E7A52-0D6B-4C7E-9A61-2F1B7E0A0003")!)
    }()

    public static let builtIn: [ExportPreset] = [website, fullSizeJPEG, fullSizeTIFF]
}

/// User export presets, kept in one JSON file outside the catalog so every catalog shares them.
public final class ExportPresetStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = ExportPresetStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier", isDirectory: true)
            .appendingPathComponent("ExportPresets.json")
    }

    /// The user's presets in name order.
    public func userPresets() -> [ExportPreset] {
        Self.sorted((try? load()) ?? [])
    }

    /// Adds or replaces a user preset.
    public func save(_ preset: ExportPreset) throws {
        guard !preset.isBuiltIn else { return }
        try write(try load().filter { $0.id != preset.id } + [preset])
    }

    public func delete(_ id: UUID) throws {
        try write(try load().filter { $0.id != id })
    }

    static func sorted(_ presets: [ExportPreset]) -> [ExportPreset] {
        presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A preset that can't be read is skipped. Throws when the file exists but isn't a preset
    /// list, so saving never overwrites presets it couldn't read.
    private func load() throws -> [ExportPreset] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.preset)
    }

    private struct Lossy: Decodable {
        let preset: ExportPreset?

        init(from decoder: Decoder) throws {
            preset = try? ExportPreset(from: decoder)
        }
    }

    private func write(_ presets: [ExportPreset]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Self.sorted(presets)).write(to: fileURL, options: .atomic)
    }
}
