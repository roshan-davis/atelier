import AgentActions
import AgentMCP
import Foundation

// Atelier's Develop tools for agents (AT-050d, the Edit profile): adjust, apply_preset, sync
// and reset. Like the Organize tools, their parameters are Swift types, so the schemas agents
// see come from the code. The app runs them (Agents/AgentDevelopTools.swift), and the plain
// rules (names, values, clamping) live here so they're tested without a Mac.

/// How `adjust` treats its values.
public enum AdjustMode: String, AgentEnum {
    /// The values are the new slider positions.
    case set
    /// The values are added to each photo's own (Exposure +0.3 on every photo).
    case add
}

/// The parts of a photo's Develop settings, as Sync Settings and presets name them.
public enum DevelopPart: String, AgentEnum {
    case profile, treatment
    case whiteBalance = "white_balance"
    case exposure, tone, presence
    case toneCurve = "tone_curve"
    case hsl
    case colorGrading = "color_grading"
    case detail
    case lensCorrections = "lens_corrections"
    case transform, effects, crop, masks

    /// Lightroom's Sync Settings leaves crop and masks off unless asked.
    public static let syncDefault: [DevelopPart] = allCases.filter { $0 != .crop && $0 != .masks }
}

public struct AdjustParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var mode: AdjustMode?
    public var temperature: Double?
    public var tint: Double?
    public var exposure: Double?
    public var contrast: Double?
    public var highlights: Double?
    public var shadows: Double?
    public var whites: Double?
    public var blacks: Double?
    public var texture: Double?
    public var clarity: Double?
    public var dehaze: Double?
    public var vibrance: Double?
    public var saturation: Double?
    public var other: [String]?

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                mode: AdjustMode? = nil, temperature: Double? = nil, tint: Double? = nil, exposure: Double? = nil,
                contrast: Double? = nil, highlights: Double? = nil, shadows: Double? = nil, whites: Double? = nil,
                blacks: Double? = nil, texture: Double? = nil, clarity: Double? = nil, dehaze: Double? = nil,
                vibrance: Double? = nil, saturation: Double? = nil, other: [String]? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.mode = mode
        self.temperature = temperature
        self.tint = tint
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.vibrance = vibrance
        self.saturation = saturation
        self.other = other
    }

    public static let example = AdjustParameters(
        ids: [1], selection: false, current: false, catalog: "Atelier Catalog", mode: .add, temperature: 5500.5,
        tint: 1.5, exposure: 0.5, contrast: 1.5, highlights: 1.5, shadows: 1.5, whites: 1.5, blacks: 1.5, texture: 1.5,
        clarity: 1.5, dehaze: 1.5, vibrance: 1.5, saturation: 1.5, other: ["hue_red=10"])

    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "mode": FieldNote("set (default): the values are the new slider positions. add: they're added to each photo's own."),
        "temperature": FieldNote("White Balance Temp in kelvin, 2000 to 50000. With add, only on photos whose white balance "
                                 + "isn't As Shot."),
        "tint": FieldNote("White Balance Tint, -150 to 150."),
        "exposure": FieldNote("Exposure in stops, -5 to 5."),
        "contrast": FieldNote("-100 to 100."),
        "highlights": FieldNote("-100 to 100."),
        "shadows": FieldNote("-100 to 100."),
        "whites": FieldNote("-100 to 100."),
        "blacks": FieldNote("-100 to 100."),
        "texture": FieldNote("-100 to 100."),
        "clarity": FieldNote("-100 to 100."),
        "dehaze": FieldNote("-100 to 100."),
        "vibrance": FieldNote("-100 to 100."),
        "saturation": FieldNote("-100 to 100."),
        "other": FieldNote("Any other Develop slider as \"name=value\", such as \"hue_red=10\", \"sat_blue=-20\", "
                           + "\"grade_shadows_hue=210\", \"sharpening=40\", \"vignette=-15\", \"grain=20\". Names are get_develop's "
                           + "value names in snake_case (hueRed is hue_red)."),
    ]) { $1 }

    /// The changes asked for, in order: the named sliders, then `other`.
    public var named: [(name: String, value: Double)] {
        let fields: [(String, Double?)] = [
            ("temperature", temperature), ("tint", tint), ("exposure", exposure), ("contrast", contrast),
            ("highlights", highlights), ("shadows", shadows), ("whites", whites), ("blacks", blacks),
            ("texture", texture), ("clarity", clarity), ("dehaze", dehaze), ("vibrance", vibrance),
            ("saturation", saturation),
        ]
        return fields.compactMap { name, value in value.map { (name, $0) } }
    }
}

public struct ApplyPresetParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var preset: String

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                preset: String) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.preset = preset
    }

    public static let example = ApplyPresetParameters(ids: [1], selection: false, current: false,
                                                      catalog: "Atelier Catalog", preset: "Portra 400")
    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "preset": FieldNote("The preset's id or name, from list_items kind presets."),
    ]) { $1 }
}

public struct SyncParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var from: Int64
    public var parts: [DevelopPart]?

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                from: Int64, parts: [DevelopPart]? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.from = from
        self.parts = parts
    }

    public static let example = SyncParameters(ids: [2], selection: false, current: false, catalog: "Atelier Catalog",
                                               from: 1, parts: [.tone])
    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "from": FieldNote("The photo whose settings are copied."),
        "parts": FieldNote("Which parts to copy (default: everything but crop and masks, as Lightroom's Sync Settings)."),
    ]) { $1 }
}

public struct ResetParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var parts: [DevelopPart]?

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                parts: [DevelopPart]? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.parts = parts
    }

    public static let example = ResetParameters(ids: [1], selection: false, current: false, catalog: "Atelier Catalog",
                                                parts: [.tone])
    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "parts": FieldNote("Reset only these parts (default: every Develop setting, as Reset All Settings)."),
    ]) { $1 }
}

/// A slider an agent may set, as the app describes it.
public struct DevelopSlider: Hashable, Sendable {
    public var name: String
    public var range: ClosedRange<Double>
    public init(name: String, range: ClosedRange<Double>) {
        self.name = name
        self.range = range
    }
}

/// The plain rules of `adjust`: names, values and clamping.
public enum AdjustRules {
    /// "hueRed" → "hue_red": Develop's parameter names as agents write them.
    public static func snakeName(_ camel: String) -> String {
        var result = ""
        for character in camel {
            if character.isUppercase || (character.isNumber && !(result.last?.isNumber ?? false)) {
                if !result.isEmpty { result.append("_") }
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// The changes a call asks for, checked against the sliders the app has. A name that's given
    /// twice, isn't a slider, or a value that isn't a number refuses the whole call.
    public static func changes(_ parameters: AdjustParameters,
                               sliders: [String: DevelopSlider]) -> Result<[(DevelopSlider, Double)], ParameterCheck.Problems> {
        var problems: [String] = []
        var result: [(DevelopSlider, Double)] = []
        var seen: Set<String> = []
        var asked = parameters.named
        for entry in parameters.other ?? [] {
            let pieces = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2, !pieces[0].isEmpty else {
                problems.append("other: \"\(entry)\" isn't \"name=value\", such as \"hue_red=10\".")
                continue
            }
            let valueText = pieces[1].hasPrefix("+") ? String(pieces[1].dropFirst()) : pieces[1]
            guard let value = Double(valueText), value.isFinite else {
                problems.append("other: \"\(entry)\": \(pieces[1]) isn't a number.")
                continue
            }
            asked.append((pieces[0], value))
        }
        for (name, value) in asked {
            guard let slider = sliders[name] else {
                let hint = Suggest.closest(to: name, in: Array(sliders.keys)).map { " Did you mean \"\($0)\"?" } ?? ""
                problems.append("No Develop slider \"\(name)\".\(hint)")
                continue
            }
            guard value.isFinite else {
                problems.append("\(name): the value must be a number.")
                continue
            }
            guard seen.insert(name).inserted else {
                problems.append("\(name) is given twice.")
                continue
            }
            result.append((slider, value))
        }
        if result.isEmpty, problems.isEmpty {
            problems.append("adjust needs at least one slider: exposure, contrast, … or other: [\"hue_red=10\"].")
        }
        return problems.isEmpty ? .success(result) : .failure(ParameterCheck.Problems(messages: problems))
    }

    /// One slider's new value from its current one: set or add, then kept inside the slider's
    /// range. `clamped` says the agent asked for more than the slider goes.
    public static func value(current: Double, asked: Double, mode: AdjustMode,
                             range: ClosedRange<Double>) -> (value: Double, clamped: Bool) {
        let wanted = mode == .add ? current + asked : asked
        let value = min(max(wanted, range.lowerBound), range.upperBound)
        return (value, value != wanted)
    }

    /// "Exposure +0.50, Contrast +20": the change's name in the notice, history and log.
    public static func title(_ changes: [(DevelopSlider, Double)], mode: AdjustMode) -> String {
        let parts = changes.prefix(3).map { slider, value -> String in
            let label = slider.name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            let number: String
            if slider.name == "exposure" {
                number = mode == .add ? String(format: "%+.2f", value) : String(format: "%.2f", value)
            } else if slider.name == "temperature", mode == .set {
                number = "\(Int(value.rounded())) K"
            } else {
                number = mode == .add ? String(format: "%+g", value) : String(format: "%g", value)
            }
            return "\(label) \(mode == .add ? "" : "to ")\(number)"
        }
        let more = changes.count > 3 ? " and \(changes.count - 3) more" : ""
        return parts.joined(separator: ", ") + more
    }
}

public extension AtelierAgentTools {
    static let adjust = MCPTool(
        name: "adjust", title: "Adjust Develop sliders",
        description: "Sets or nudges Develop sliders on photos: White Balance, Exposure, Contrast, Highlights, Shadows, Whites, "
            + "Blacks, Texture, Clarity, Dehaze, Vibrance, Saturation, and any other slider by name (HSL, Color Grading, "
            + "Detail, Effects). Values outside a slider's range are kept at its end. One call is one change: one step in "
            + "each photo's Develop history, named for you, and undo_change undoes it. Use get_develop to read the values first.",
        inputSchema: ParameterSchema.of(AdjustParameters.self).json, readOnly: false)

    static let applyPreset = MCPTool(
        name: "apply_preset", title: "Apply a Develop preset",
        description: "Applies a Develop preset to photos, on top of each photo's own settings (only the parts the preset "
            + "holds change). One change; undo_change undoes it.",
        inputSchema: ParameterSchema.of(ApplyPresetParameters.self).json, readOnly: false)

    static let sync = MCPTool(
        name: "sync", title: "Sync settings from a photo",
        description: "Copies Develop settings from one photo onto others, like Lightroom's Sync Settings: the parts you "
            + "name, or everything but crop and masks. One change; undo_change undoes it.",
        inputSchema: ParameterSchema.of(SyncParameters.self).json, readOnly: false)

    static let reset = MCPTool(
        name: "reset", title: "Reset Develop settings",
        description: "Resets photos' Develop settings, all of them or only the parts you name. One change; undo_change "
            + "undoes it.",
        inputSchema: ParameterSchema.of(ResetParameters.self).json, readOnly: false)

    /// The Develop tools the Edit profile adds.
    static let editTools = [adjust, applyPreset, sync, reset]

    static let developParameterSchemas: [String: ParameterSchema] = [
        adjust.name: .of(AdjustParameters.self),
        applyPreset.name: .of(ApplyPresetParameters.self),
        sync.name: .of(SyncParameters.self),
        reset.name: .of(ResetParameters.self),
    ]
}
