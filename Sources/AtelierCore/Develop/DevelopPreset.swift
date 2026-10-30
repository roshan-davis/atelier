import Foundation

/// A saved look: some parts of a photo's develop settings, applied on top of another photo's
/// settings without touching the parts it leaves out.
public struct DevelopPreset: Codable, Hashable, Sendable, Identifiable {
    /// The pieces a preset can include, as in Lightroom's Create Preset dialog, in Develop
    /// panel order.
    public enum Part: String, Codable, CaseIterable, Sendable {
        case profile, treatment, whiteBalance, exposure, tone, presence, toneCurve, hsl, colorGrading, detail
        case lensCorrections, transform, effects, crop, masks

        public var title: String {
            switch self {
            case .profile: return "Profile"
            case .treatment: return "Treatment & B&W Mix"
            case .whiteBalance: return "White Balance"
            case .exposure: return "Exposure"
            case .tone: return "Tone"
            case .presence: return "Presence"
            case .toneCurve: return "Tone Curve"
            case .hsl: return "HSL / Color"
            case .colorGrading: return "Color Grading"
            case .detail: return "Detail"
            case .lensCorrections: return "Lens Corrections"
            case .transform: return "Transform"
            case .effects: return "Effects"
            case .crop: return "Crop & Straighten"
            case .masks: return "Masks"
            }
        }

        /// What the part covers, for the Create Preset dialog.
        public var detail: String? {
            switch self {
            case .tone: return "Contrast, Highlights, Shadows, Whites, Blacks"
            case .presence: return "Texture, Clarity, Dehaze, Vibrance, Saturation"
            default: return nil
            }
        }

        /// Most presets are a look; the profile, white balance, lens corrections, transform, crop
        /// and masks depend on the photo, so they are left out unless chosen.
        public static let defaults: Set<Part> = Set(allCases)
            .subtracting([.profile, .whiteBalance, .lensCorrections, .transform, .crop, .masks])

        var parameters: [DevelopSettings.Parameter] {
            switch self {
            case .treatment: return DevelopSettings.ColorBand.allCases.map { .gray($0) }
            case .whiteBalance: return [.temperature, .tint]
            case .exposure: return [.exposure]
            case .tone: return [.contrast, .highlights, .shadows, .whites, .blacks]
            case .presence: return [.texture, .clarity, .dehaze, .vibrance, .saturation]
            case .toneCurve: return DevelopSettings.Panel.toneCurve.parameters
            case .hsl: return DevelopSettings.Panel.hsl.parameters.filter { $0.grayBand == nil }
            case .colorGrading: return DevelopSettings.Panel.colorGrading.parameters
            case .detail: return DevelopSettings.Panel.detail.parameters
            case .effects: return DevelopSettings.Panel.effects.parameters
            case .lensCorrections: return DevelopSettings.Panel.lensCorrections.parameters
            case .transform: return DevelopSettings.Panel.transform.parameters
            case .profile, .crop, .masks: return []
            }
        }

        /// The panel whose switch the part carries, for parts that are a whole panel.
        var panel: DevelopSettings.Panel? {
            switch self {
            case .toneCurve: return .toneCurve
            case .hsl: return .hsl
            case .colorGrading: return .colorGrading
            case .detail: return .detail
            case .effects: return .effects
            case .lensCorrections: return .lensCorrections
            case .transform: return .transform
            default: return nil
            }
        }

        /// Whether `settings` has anything in this part away from its default.
        public func isChanged(in settings: DevelopSettings) -> Bool {
            let parametersChanged = parameters.contains { $0 != .temperature && settings[$0] != $0.defaultValue }
                || panel.map { !settings.isOn($0) } == true
            switch self {
            case .profile: return settings.profile != .cameraMatching
            case .treatment: return settings.monochrome || parametersChanged
            case .whiteBalance: return settings.temperature != nil || parametersChanged
            case .toneCurve: return settings.hasPointCurve || parametersChanged
            case .lensCorrections:
                return !settings.lensProfileCorrections || settings.removeChromaticAberration || parametersChanged
            case .transform: return settings.upright != nil || settings.constrainCrop || parametersChanged
            case .crop: return settings.crop != nil
            case .masks: return !settings.masks.isEmpty
            default: return parametersChanged
            }
        }

        /// The parts `settings` changes from the defaults.
        public static func changed(in settings: DevelopSettings) -> Set<Part> {
            Set(allCases.filter { $0.isChanged(in: settings) })
        }
    }

    /// Where presets go when no group is chosen.
    public static let defaultGroup = "User Presets"

    public var id: UUID
    public var name: String
    /// The group it is listed under.
    public var group: String
    public var parts: Set<Part>
    public var settings: DevelopSettings
    /// Built-in presets can't be changed or deleted.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, group: String = DevelopPreset.defaultGroup,
                parts: Set<Part> = Part.defaults, settings: DevelopSettings, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.group = group
        self.parts = parts
        self.settings = settings
        self.isBuiltIn = isBuiltIn
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case id, name, group, parts, settings, isBuiltIn, partsVersion
    }

    /// Version 2 split Exposure out of Tone.
    private static let partsVersion = 2

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? Self.defaultGroup
        // A part this version doesn't know is skipped rather than losing the preset.
        let rawParts = try c.decodeIfPresent([String].self, forKey: .parts) ?? []
        parts = Set(rawParts.compactMap(Part.init(rawValue:)))
        let version = try c.decodeIfPresent(Int.self, forKey: .partsVersion) ?? 1
        if version < 2, parts.contains(.tone) { parts.insert(.exposure) }
        settings = try c.decode(DevelopSettings.self, forKey: .settings)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(group, forKey: .group)
        try c.encode(parts.map(\.rawValue).sorted(), forKey: .parts)
        try c.encode(settings, forKey: .settings)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encode(Self.partsVersion, forKey: .partsVersion)
    }

    // MARK: Applying

    /// `base` with this preset's parts replaced.
    public func applied(to base: DevelopSettings) -> DevelopSettings {
        var result = base
        for part in parts {
            switch part {
            case .whiteBalance:
                result.temperature = settings.temperature
            case .crop:
                result.crop = settings.crop
            case .masks:
                result.masks = settings.masks
            case .profile:
                result.profile = settings.profile
            case .treatment:
                result.monochrome = settings.monochrome
            case .lensCorrections:
                result.lensProfileCorrections = settings.lensProfileCorrections
                result.removeChromaticAberration = settings.removeChromaticAberration
            case .transform:
                result.upright = settings.upright
                result.constrainCrop = settings.constrainCrop
            case .toneCurve:
                for channel in DevelopSettings.CurveChannel.allCases {
                    result.setPoints(settings.points(for: channel), for: channel)
                }
            default:
                break
            }
            for parameter in part.parameters where parameter != .temperature {
                result[parameter] = settings[parameter]
            }
            if let panel = part.panel { result.setPanel(panel, on: settings.isOn(panel)) }
        }
        return result
    }

    /// The preset at `amount` (0 to 2, 1 is the preset as saved), like Lightroom's preset Amount:
    /// each slider the preset moves goes that fraction of the way from `base`, and past it above 1.
    /// Point curves blend the same way. Color grading hues, picked Point Colors, styles, white
    /// balance on photos left as shot, and switches (treatment, profile, crop, masks, Color
    /// Grading on or off) take the preset's value.
    public func applied(to base: DevelopSettings, amount: Double) -> DevelopSettings {
        let full = applied(to: base)
        guard amount != 1 else { return full }
        guard amount > 0 else { return base }
        var result = full
        for parameter in DevelopSettings.Parameter.allCases {
            let from = base[parameter], to = full[parameter]
            guard from != to else { continue }
            switch parameter {
            case .temperature:
                if base.temperature != nil, full.temperature != nil {
                    result[.temperature] = from + (to - from) * amount
                }
            default:
                guard parameter.blendsLinearly else { break }
                result[parameter] = from + (to - from) * amount
            }
        }
        for channel in DevelopSettings.CurveChannel.allCases {
            let from = base.points(for: channel), to = full.points(for: channel)
            guard from != to else { continue }
            let samples = 9
            let points = (0..<samples).map { index -> DevelopSettings.CurvePoint in
                let x = Double(index) / Double(samples - 1)
                let a = DevelopRenderer.pointCurveValue(from, at: x)
                let b = DevelopRenderer.pointCurveValue(to, at: x)
                return DevelopSettings.CurvePoint(x: x, y: a + (b - a) * amount)
            }
            result.setPoints(points, for: channel)
        }
        return result
    }
}

/// User presets, kept in one JSON file outside the catalog so every catalog shares them.
public final class PresetStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier", isDirectory: true)
            .appendingPathComponent("Presets.json")
    }

    /// The user's presets first (User Presets, then their other groups by name), then the
    /// built-in packs in their fixed order. Presets are in name order within a group.
    public func all() -> [DevelopPreset] {
        Self.sorted(userPresets()) + DevelopPreset.builtIn
    }

    static func sorted(_ presets: [DevelopPreset]) -> [DevelopPreset] {
        presets.sorted { a, b in
            let aDefault = a.group == DevelopPreset.defaultGroup, bDefault = b.group == DevelopPreset.defaultGroup
            if aDefault != bDefault { return aDefault }
            let groupOrder = a.group.localizedStandardCompare(b.group)
            if groupOrder != .orderedSame { return groupOrder == .orderedAscending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public func userPresets() -> [DevelopPreset] {
        (try? load()) ?? []
    }

    /// The saved presets; a preset that can't be read is skipped. Throws when the file exists
    /// but isn't a preset list, so saving never overwrites presets it couldn't read.
    private func load() throws -> [DevelopPreset] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.preset)
    }

    private struct Lossy: Decodable {
        let preset: DevelopPreset?

        init(from decoder: Decoder) throws {
            preset = try? DevelopPreset(from: decoder)
        }
    }

    /// Adds or replaces a user preset.
    public func save(_ preset: DevelopPreset) throws {
        try save([preset])
    }

    /// Adds or replaces several user presets at once.
    public func save(_ changed: [DevelopPreset]) throws {
        let changed = changed.filter { !$0.isBuiltIn }
        guard !changed.isEmpty else { return }
        let ids = Set(changed.map(\.id))
        try write(try load().filter { !ids.contains($0.id) } + changed)
    }

    public func delete(_ id: UUID) throws {
        try write(try load().filter { $0.id != id })
    }

    /// Moves every preset in `group` to `newName`.
    public func renameGroup(_ group: String, to newName: String) throws {
        try write(try load().map { preset in
            var preset = preset
            if preset.group == group { preset.group = newName }
            return preset
        })
    }

    /// Deletes the group and its presets; returns how many presets went with it.
    @discardableResult
    public func deleteGroup(_ group: String) throws -> Int {
        let presets = try load()
        let kept = presets.filter { $0.group != group }
        try write(kept)
        return presets.count - kept.count
    }

    private func write(_ presets: [DevelopPreset]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Self.sorted(presets)).write(to: fileURL, options: .atomic)
    }
}
