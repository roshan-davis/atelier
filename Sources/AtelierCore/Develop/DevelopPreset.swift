import Foundation

/// A saved look: some parts of a photo's develop settings, applied on top of another photo's
/// settings without touching the parts it leaves out.
public struct DevelopPreset: Codable, Hashable, Sendable, Identifiable {
    /// The pieces a preset can include, as in Lightroom's New Preset dialog.
    public enum Part: String, Codable, CaseIterable, Sendable {
        case profile, whiteBalance, tone, presence, toneCurve, hsl, colorGrading, detail, lensCorrections, transform
        case effects, crop, masks

        public var title: String {
            switch self {
            case .profile: return "Profile"
            case .whiteBalance: return "White Balance"
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

        /// Most presets are a look; the profile, white balance, lens corrections, transform, crop
        /// and masks depend on the photo, so they are left out unless chosen.
        public static let defaults: Set<Part> = Set(allCases)
            .subtracting([.profile, .whiteBalance, .lensCorrections, .transform, .crop, .masks])

        var parameters: [DevelopSettings.Parameter] {
            switch self {
            case .whiteBalance: return [.temperature, .tint]
            case .tone: return [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
            case .presence: return [.texture, .clarity, .dehaze, .vibrance, .saturation]
            case .toneCurve: return DevelopSettings.Panel.toneCurve.parameters
            case .hsl: return DevelopSettings.Panel.hsl.parameters
            case .colorGrading: return DevelopSettings.Panel.colorGrading.parameters
            case .detail: return DevelopSettings.Panel.detail.parameters
            case .effects: return DevelopSettings.Panel.effects.parameters
            case .lensCorrections: return DevelopSettings.Panel.lensCorrections.parameters
            case .transform: return DevelopSettings.Panel.transform.parameters
            case .profile, .crop, .masks: return []
            }
        }
    }

    public var id: UUID
    public var name: String
    /// The group it is listed under.
    public var group: String
    public var parts: Set<Part>
    public var settings: DevelopSettings
    /// Built-in presets can't be changed or deleted.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, group: String = "User Presets", parts: Set<Part> = Part.defaults,
                settings: DevelopSettings, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.group = group
        self.parts = parts
        self.settings = settings
        self.isBuiltIn = isBuiltIn
    }

    /// `base` with this preset's parts replaced.
    public func applied(to base: DevelopSettings) -> DevelopSettings {
        var result = base
        for part in parts {
            switch part {
            case .whiteBalance:
                result.temperature = settings.temperature
                result[.tint] = settings[.tint]
            case .crop:
                result.crop = settings.crop
            case .masks:
                result.masks = settings.masks
            case .profile:
                result.profile = settings.profile
            case .lensCorrections:
                result.lensProfileCorrections = settings.lensProfileCorrections
                for parameter in part.parameters { result[parameter] = settings[parameter] }
            case .transform:
                result.upright = settings.upright
                result.constrainCrop = settings.constrainCrop
                for parameter in part.parameters { result[parameter] = settings[parameter] }
            case .toneCurve:
                for channel in DevelopSettings.CurveChannel.allCases {
                    result.setPoints(settings.points(for: channel), for: channel)
                }
                fallthrough
            default:
                for parameter in part.parameters where parameter != .temperature {
                    result[parameter] = settings[parameter]
                }
            }
        }
        return result
    }
}

extension DevelopPreset {
    /// A few starting looks, listed under "Atelier".
    public static let builtIn: [DevelopPreset] = {
        func preset(_ id: String, _ name: String, parts: Set<Part> = Part.defaults,
                    _ configure: (inout DevelopSettings) -> Void) -> DevelopPreset {
            var settings = DevelopSettings()
            configure(&settings)
            return DevelopPreset(id: UUID(uuidString: id)!, name: name, group: "Atelier", parts: parts,
                                 settings: settings, isBuiltIn: true)
        }
        return [
            preset("6E2B6B5A-0001-4C5E-9A7E-0A7E11E50001", "Clean Product") { s in
                s.highlights = -25
                s.shadows = 20
                s.whites = 10
                s.clarity = 5
                s.vibrance = 10
                s.sharpening = 50
            },
            preset("6E2B6B5A-0002-4C5E-9A7E-0A7E11E50002", "Punchy") { s in
                s.contrast = 20
                s.clarity = 15
                s.vibrance = 25
                s.dehaze = 5
            },
            preset("6E2B6B5A-0003-4C5E-9A7E-0A7E11E50003", "Soft Matte") { s in
                s.contrast = -10
                s.highlights = -15
                s.setPoints([.init(x: 0, y: 0.08), .init(x: 0.5, y: 0.52), .init(x: 1, y: 0.95)], for: .rgb)
                s.saturation = -10
            },
            preset("6E2B6B5A-0004-4C5E-9A7E-0A7E11E50004", "Warm Film") { s in
                s[.gradeShadowsHue] = 200
                s[.gradeShadowsSat] = 15
                s[.gradeHighlightsHue] = 40
                s[.gradeHighlightsSat] = 20
                s.contrast = 10
                s.grain = 20
                s.vignette = -15
            },
            preset("6E2B6B5A-0005-4C5E-9A7E-0A7E11E50005", "Black & White") { s in
                s.saturation = -100
                s.contrast = 20
                s.clarity = 10
            },
        ]
    }()
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

    /// Built-in presets first, then the user's, each sorted by group and name.
    public func all() -> [DevelopPreset] {
        DevelopPreset.builtIn + userPresets().sorted {
            ($0.group.localizedLowercase, $0.name.localizedLowercase) < ($1.group.localizedLowercase, $1.name.localizedLowercase)
        }
    }

    public func userPresets() -> [DevelopPreset] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([DevelopPreset].self, from: data)) ?? []
    }

    /// Adds or replaces a user preset.
    public func save(_ preset: DevelopPreset) throws {
        guard !preset.isBuiltIn else { return }
        var presets = userPresets().filter { $0.id != preset.id }
        presets.append(preset)
        try write(presets)
    }

    public func delete(_ id: UUID) throws {
        try write(userPresets().filter { $0.id != id })
    }

    private func write(_ presets: [DevelopPreset]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: fileURL, options: .atomic)
    }
}
