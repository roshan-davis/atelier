import AgentActions
import AgentMCP
import Foundation

// The rest of AT-050d's typed Edit tools: crop, add_mask, auto and match_look. As with adjust,
// the parameter types are Swift, the schemas come from them, and the plain rules (what a call
// asks for, ranges, refusals, history names) live here so they're tested without a Mac. The app
// runs them in Agents/AgentEditTools.swift.

// MARK: crop

public enum CropTurn: String, AgentEnum {
    /// A quarter turn counterclockwise (⌘[).
    case left
    /// A quarter turn clockwise (⌘]).
    case right
}

public enum CropFlip: String, AgentEnum {
    case horizontal, vertical
}

public enum CropOrientation: String, AgentEnum {
    case landscape, portrait
}

public struct CropParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var reset: Bool?
    public var rotate: CropTurn?
    public var flip: CropFlip?
    public var angle: Double?
    public var aspect: String?
    public var orientation: CropOrientation?
    public var box: [Double]?

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                reset: Bool? = nil, rotate: CropTurn? = nil, flip: CropFlip? = nil, angle: Double? = nil,
                aspect: String? = nil, orientation: CropOrientation? = nil, box: [Double]? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.reset = reset
        self.rotate = rotate
        self.flip = flip
        self.angle = angle
        self.aspect = aspect
        self.orientation = orientation
        self.box = box
    }

    public static let example = CropParameters(
        ids: [1], selection: false, current: false, catalog: "Atelier Catalog", reset: false, rotate: .right,
        flip: .horizontal, angle: 1.5, aspect: "4x5", orientation: .portrait, box: [0.1, 0.1, 0.8, 0.8])

    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "reset": FieldNote("true: first remove the crop, straightening, rotation and flips, as the crop tool's Reset."),
        "rotate": FieldNote("A quarter turn: left (⌘[) or right (⌘]). The crop frame turns with the photo."),
        "flip": FieldNote("Flip the photo horizontally or vertically."),
        "angle": FieldNote("Straighten angle in degrees; positive turns the photo clockwise. The crop shrinks to stay "
                           + "on the photo, as in Lightroom.", minimum: -45, maximum: 45),
        "aspect": FieldNote("Lock the crop to an aspect ratio, at the largest size that fits around the crop's center: "
                            + "original, free (unlock), 1x1, 4x5, 5x7, 2x3, 3x4, 16x10, 16x9, or any \"w:h\". The crop "
                            + "keeps its orientation unless orientation is given."),
        "orientation": FieldNote("landscape or portrait: the crop's orientation (X in the crop tool)."),
        "box": FieldNote("The crop as [x, y, width, height], fractions 0 to 1 of the whole photo as turned, before "
                         + "cropping (0, 0 is the top left). Not with aspect. Kept on the photo if it straightens."),
    ]) { $1 }
}

/// An aspect ratio an agent asks for.
public enum CropAspectChoice: Hashable, Sendable {
    case original
    case free
    /// Width / height, as written (4x5 is 0.8); the crop's orientation decides which way it goes.
    case ratio(Double, label: String)

    /// The landscape width / height of a ratio (4x5 → 1.25).
    public var landscape: Double? {
        guard case .ratio(let value, _) = self else { return nil }
        return value >= 1 ? value : 1 / value
    }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .free: return "Free"
        case .ratio(_, let label): return label
        }
    }
}

/// The plain rules of `crop`.
public enum CropRules {
    /// What a call asks for, checked.
    public struct Plan: Hashable, Sendable {
        public var reset: Bool
        public var rotate: CropTurn?
        public var flip: CropFlip?
        public var angle: Double?
        public var aspect: CropAspectChoice?
        public var orientation: CropOrientation?
        /// x, y, width, height.
        public var box: [Double]?
        public var title: String
    }

    /// "4x5", "4 × 5", "4:5", "1.5", "original", "free".
    public static func aspect(_ text: String) -> CropAspectChoice? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch cleaned {
        case "original", "as shot", "as_shot": return .original
        case "free", "none", "unlocked": return .free
        default: break
        }
        let separators = CharacterSet(charactersIn: "x×:/")
        let pieces = cleaned.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }
        if pieces.count == 2, let w = Double(pieces[0]), let h = Double(pieces[1]), w > 0, h > 0, w.isFinite, h.isFinite {
            return .ratio(w / h, label: "\(format(w)) × \(format(h))")
        }
        if pieces.count == 1, let value = Double(cleaned), value > 0, value.isFinite {
            return .ratio(value, label: format(value) + " × 1")
        }
        return nil
    }

    public static func plan(_ parameters: CropParameters) -> Result<Plan, ParameterCheck.Problems> {
        var problems: [String] = []
        var titles: [String] = []
        let reset = parameters.reset ?? false
        if reset { titles.append("Reset Crop") }
        if let rotate = parameters.rotate { titles.append(rotate == .left ? "Rotate Left" : "Rotate Right") }
        if let flip = parameters.flip { titles.append(flip == .horizontal ? "Flip Horizontal" : "Flip Vertical") }
        if let angle = parameters.angle {
            if !angle.isFinite || abs(angle) > 45 {
                problems.append("angle: \(angle) is outside -45 to 45 degrees.")
            } else {
                titles.append(String(format: "Straighten %.1f°", angle))
            }
        }
        var aspect: CropAspectChoice?
        if let text = parameters.aspect {
            if let found = Self.aspect(text) {
                aspect = found
                titles.append(found == .free ? "Crop Aspect: Free" : "Crop \(found.title)")
            } else {
                problems.append("aspect: \"\(text)\" isn't original, free, or a ratio such as \"4x5\" or \"16:9\".")
            }
        }
        if let orientation = parameters.orientation {
            if aspect == .free {
                problems.append("orientation needs a locked aspect; free has none.")
            }
            if aspect == nil { titles.append(orientation == .portrait ? "Crop Portrait" : "Crop Landscape") }
        }
        if let box = parameters.box {
            if parameters.aspect != nil || parameters.orientation != nil {
                problems.append("Give box or aspect and orientation, not both: box already sets the crop's shape.")
            }
            if box.count != 4 || !box.allSatisfy(\.isFinite) {
                problems.append("box: give 4 numbers, [x, y, width, height].")
            } else {
                let (x, y, w, h) = (box[0], box[1], box[2], box[3])
                let tolerance = 1e-6
                if x < -tolerance || y < -tolerance || w <= 0.01 || h <= 0.01
                    || x + w > 1 + tolerance || y + h > 1 + tolerance {
                    problems.append("box: [x, y, width, height] must lie on the photo: each 0 to 1, x + width and "
                                    + "y + height at most 1, width and height above 0.01.")
                } else {
                    titles.append("Crop")
                }
            }
        }
        if titles.isEmpty, problems.isEmpty {
            problems.append("crop needs at least one of reset, rotate, flip, angle, aspect, orientation or box.")
        }
        guard problems.isEmpty else { return .failure(ParameterCheck.Problems(messages: problems)) }
        return .success(Plan(reset: reset, rotate: parameters.rotate, flip: parameters.flip, angle: parameters.angle,
                             aspect: aspect, orientation: parameters.orientation, box: parameters.box,
                             title: titles.joined(separator: ", ")))
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}

// MARK: add_mask

/// The mask kinds an agent can add. Brush stays manual.
public enum AgentMaskKind: String, AgentEnum {
    case subject, background, object, people, linear, radial, luminance, depth

    /// The Masks panel's name.
    public var title: String {
        switch self {
        case .subject: return "Select Subject"
        case .background: return "Select Background"
        case .object: return "Select Object"
        case .people: return "Select People"
        case .linear: return "Linear Gradient"
        case .radial: return "Radial Gradient"
        case .luminance: return "Luminance Range"
        case .depth: return "Depth Range"
        }
    }
}

public enum MaskCombine: String, AgentEnum {
    case add, subtract, intersect

    public var verb: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Select People's parts, as the Masks panel lists them.
public enum AgentPeoplePart: String, AgentEnum {
    case faceSkin = "face_skin"
    case bodySkin = "body_skin"
    case eyebrows
    case eyeSclera = "eye_sclera"
    case iris, lips, teeth, hair, clothes
    case entirePerson = "entire_person"
    case entireFace = "entire_face"
}

public struct AddMaskParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var kind: AgentMaskKind
    public var name: String?
    public var toMask: String?
    public var combine: MaskCombine?
    public var box: [Double]?
    public var start: [Double]?
    public var end: [Double]?
    public var center: [Double]?
    public var size: [Double]?
    public var feather: Double?
    public var range: [Double]?
    public var smoothness: Double?
    public var person: Int?
    public var parts: [AgentPeoplePart]?
    public var refine: Double?
    public var grow: Double?
    public var invert: Bool?
    public var amount: Double?
    public var settings: [String]?

    enum CodingKeys: String, CodingKey {
        case ids, selection, current, catalog, kind, name
        case toMask = "to_mask"
        case combine, box, start, end, center, size, feather, range, smoothness, person, parts, refine, grow, invert,
             amount, settings
    }

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                kind: AgentMaskKind, name: String? = nil, toMask: String? = nil, combine: MaskCombine? = nil,
                box: [Double]? = nil, start: [Double]? = nil, end: [Double]? = nil, center: [Double]? = nil,
                size: [Double]? = nil, feather: Double? = nil, range: [Double]? = nil, smoothness: Double? = nil,
                person: Int? = nil, parts: [AgentPeoplePart]? = nil, refine: Double? = nil, grow: Double? = nil,
                invert: Bool? = nil, amount: Double? = nil, settings: [String]? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.kind = kind
        self.name = name
        self.toMask = toMask
        self.combine = combine
        self.box = box
        self.start = start
        self.end = end
        self.center = center
        self.size = size
        self.feather = feather
        self.range = range
        self.smoothness = smoothness
        self.person = person
        self.parts = parts
        self.refine = refine
        self.grow = grow
        self.invert = invert
        self.amount = amount
        self.settings = settings
    }

    public static let example = AddMaskParameters(
        ids: [1], selection: false, current: false, catalog: "Atelier Catalog", kind: .linear, name: "Sky",
        toMask: "Mask 1", combine: .add, box: [0.3, 0.3, 0.4, 0.4], start: [0.5, 0], end: [0.5, 0.4],
        center: [0.5, 0.5], size: [0.2, 0.15], feather: 50, range: [50, 100], smoothness: 50, person: 0,
        parts: [.faceSkin], refine: 0, grow: 0, invert: false, amount: 100, settings: ["exposure=-0.5"])

    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "kind": FieldNote("subject (Select Subject), background (Select Background: all but the subject), object (Select Object, needs box), people (Select People), "
                          + "linear (Linear Gradient), radial (Radial Gradient), luminance (Luminance Range) or depth (Depth Range: "
                          + "how far away, needs the depth model from Settings > AI). Brush "
                          + "is drawn by hand."),
        "name": FieldNote("The new mask's name (default \"Mask n\"). Not with to_mask."),
        "to_mask": FieldNote("Add this part to the photo's existing mask of this name (get_develop lists masks) instead "
                             + "of making a new mask."),
        "combine": FieldNote("With to_mask: add (default), subtract or intersect the part, as the Masks panel's Add, "
                             + "Subtract and Intersect."),
        "box": FieldNote("object: the box around the object as [x, y, width, height]. Points and sizes are fractions 0 "
                         + "to 1 of the photo as get_preview shows it (cropped), from its top left."),
        "start": FieldNote("linear: [x, y] where the effect is full (default [0.5, 0.2])."),
        "end": FieldNote("linear: [x, y] where it has faded out (default [0.5, 0.5])."),
        "center": FieldNote("radial: the ellipse's center [x, y] (default [0.5, 0.5])."),
        "size": FieldNote("radial: half-width and half-height [w, h], fractions of the shown photo's width and height "
                          + "(default [0.25, 0.25])."),
        "feather": FieldNote("radial: how much of the ellipse fades (default 50). subject, background, object, people: softens the "
                             + "edge (default 20, people 10).", minimum: 0, maximum: 100),
        "range": FieldNote("luminance: [low, high] brightness kept, 0 to 100 (default [50, 100]). depth: [near, far] "
                           + "depth kept, 0 the nearest part of the photo to 100 the farthest (default [0, 30])."),
        "smoothness": FieldNote("luminance, depth: how softly the range fades (default 50).", minimum: 0, maximum: 100),
        "person": FieldNote("people: which person, counted from the left from 0; leave out for everyone."),
        "parts": FieldNote("people: the parts to select (default face_skin and body_skin)."),
        "refine": FieldNote("subject, background, object, people: snaps the edge to the photo's edges (0 is off).",
                            minimum: 0, maximum: 100),
        "grow": FieldNote("subject, background, object, people: shrinks (below 0) or grows the selection.", minimum: -100, maximum: 100),
        "invert": FieldNote("true: invert the new part (with to_mask) or the new mask."),
        "amount": FieldNote("New mask only: scales all of its sliders, percent (default 100).", minimum: 0, maximum: 200),
        "settings": FieldNote("New mask only: its sliders as \"name=value\": temperature, tint, exposure, contrast, "
                              + "highlights, shadows, whites, blacks, texture, clarity, dehaze, hue (degrees, -180 to 180), "
                              + "saturation, sharpness, noise, moire, defringe; and its own Color Grading: grade_shadows_hue, "
                              + "grade_shadows_sat, grade_shadows_lum (also midtones, highlights, global), grade_blending, "
                              + "grade_balance. Example [\"exposure=-0.5\", \"clarity=20\"]."),
    ]) { $1 }
}

/// The plain rules of `add_mask`.
public enum MaskRules {
    /// A checked call, in the agent's own coordinates (fractions of the photo as shown).
    public struct Plan: Hashable, Sendable {
        public var kind: AgentMaskKind
        public var name: String?
        public var toMask: String?
        public var combine: MaskCombine
        public var box: [Double]?
        public var start: [Double]
        public var end: [Double]
        public var center: [Double]
        public var size: [Double]
        public var feather: Double?
        public var range: [Double]
        public var smoothness: Double
        public var person: Int?
        public var parts: [AgentPeoplePart]
        public var refine: Double
        public var grow: Double
        public var invert: Bool
        public var amount: Double?
        public var settings: [MaskSetting]
        public var title: String
    }

    /// One of a new mask's sliders.
    public struct MaskSetting: Hashable, Sendable {
        public var name: String
        public var value: Double
    }

    /// The fields each kind takes; any other kind-specific field refuses the call.
    static let fields: [AgentMaskKind: Set<String>] = [
        .subject: ["feather", "refine", "grow"],
        .background: ["feather", "refine", "grow"],
        .object: ["box", "feather", "refine", "grow"],
        .people: ["person", "parts", "feather", "refine", "grow"],
        .linear: ["start", "end"],
        .radial: ["center", "size", "feather"],
        .luminance: ["range", "smoothness"],
        .depth: ["range", "smoothness"],
    ]

    /// `sliders` is each mask slider's name and range.
    public static func plan(_ p: AddMaskParameters,
                            sliders: [String: ClosedRange<Double>]) -> Result<Plan, ParameterCheck.Problems> {
        var problems: [String] = []
        let given: [(String, Bool)] = [
            ("box", p.box != nil), ("start", p.start != nil), ("end", p.end != nil), ("center", p.center != nil),
            ("size", p.size != nil), ("feather", p.feather != nil), ("range", p.range != nil),
            ("smoothness", p.smoothness != nil), ("person", p.person != nil), ("parts", p.parts != nil),
            ("refine", p.refine != nil), ("grow", p.grow != nil),
        ]
        let allowed = fields[p.kind] ?? []
        for (field, isGiven) in given where isGiven && !allowed.contains(field) {
            let owners = fields.filter { $0.value.contains(field) }.map(\.key.rawValue).sorted()
            problems.append("\(field) is for \(owners.joined(separator: " and ")), not \(p.kind.rawValue).")
        }

        func point(_ value: [Double]?, _ field: String, default fallback: [Double], range: ClosedRange<Double>) -> [Double] {
            guard let value else { return fallback }
            guard value.count == 2, value.allSatisfy({ $0.isFinite && range.contains($0) }) else {
                problems.append("\(field): give [x, y], each \(CropRules.format(range.lowerBound)) to "
                                + "\(CropRules.format(range.upperBound)).")
                return fallback
            }
            return value
        }
        func number(_ value: Double?, _ field: String, _ range: ClosedRange<Double>) -> Double? {
            guard let value else { return nil }
            guard value.isFinite, range.contains(value) else {
                problems.append("\(field): \(value) is outside \(CropRules.format(range.lowerBound)) to "
                                + "\(CropRules.format(range.upperBound)).")
                return nil
            }
            return value
        }

        // Gradients may start or end off the photo, as when dragged past its edge.
        let start = point(p.start, "start", default: [0.5, 0.2], range: -1...2)
        let end = point(p.end, "end", default: [0.5, 0.5], range: -1...2)
        if p.kind == .linear, start == end { problems.append("start and end must differ.") }
        let center = point(p.center, "center", default: [0.5, 0.5], range: -1...2)
        var size = [0.25, 0.25]
        if let given = p.size {
            if given.count == 2, given.allSatisfy({ $0.isFinite && $0 > 0.001 && $0 <= 2 }) {
                size = given
            } else {
                problems.append("size: give [w, h], each above 0.001 and at most 2.")
            }
        }
        var box: [Double]?
        if p.kind == .object {
            if let given = p.box {
                if given.count == 4, given.allSatisfy(\.isFinite), given[2] > 0.005, given[3] > 0.005,
                   given[0] >= -1e-6, given[1] >= -1e-6, given[0] + given[2] <= 1 + 1e-6, given[1] + given[3] <= 1 + 1e-6 {
                    box = given
                } else {
                    problems.append("box: give [x, y, width, height] on the photo, each 0 to 1.")
                }
            } else {
                problems.append("object needs box: [x, y, width, height] around the object, as get_preview shows the photo.")
            }
        }
        let feather = number(p.feather, "feather", 0...100)
        var range = p.kind == .depth ? [0.0, 30.0] : [50.0, 100.0]
        if let given = p.range {
            if given.count == 2, given.allSatisfy({ $0.isFinite && (0...100).contains($0) }), given[0] < given[1] {
                range = given
            } else {
                problems.append("range: give [low, high], 0 to 100, low below high.")
            }
        }
        let smoothness = number(p.smoothness, "smoothness", 0...100) ?? 50
        if let person = p.person, person < 0 { problems.append("person counts from 0 (the leftmost person).") }
        if let parts = p.parts, parts.isEmpty { problems.append("parts is empty: name at least one, or leave it out.") }
        let refine = number(p.refine, "refine", 0...100) ?? 0
        let grow = number(p.grow, "grow", -100...100) ?? 0
        let amount = number(p.amount, "amount", 0...200)

        let name = p.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toMask = p.toMask?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.isEmpty { problems.append("name is empty.") }
        if let toMask, toMask.isEmpty { problems.append("to_mask is empty.") }
        if toMask != nil {
            if p.name != nil { problems.append("name is for a new mask; to_mask adds to one that exists.") }
            if p.amount != nil || p.settings != nil {
                problems.append("amount and settings are for a new mask; change an existing mask's sliders in Masking.")
            }
        } else if p.combine != nil, p.combine != .add {
            problems.append("combine \(p.combine!.rawValue) needs to_mask: a new mask can only add.")
        }

        var settings: [MaskSetting] = []
        var seen: Set<String> = []
        for entry in p.settings ?? [] {
            let pieces = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let valueText = pieces.count == 2 && pieces[1].hasPrefix("+") ? String(pieces[1].dropFirst())
                : (pieces.count == 2 ? pieces[1] : "")
            guard pieces.count == 2, !pieces[0].isEmpty, let value = Double(valueText), value.isFinite else {
                problems.append("settings: \"\(entry)\" isn't \"name=value\", such as \"exposure=-0.5\".")
                continue
            }
            let key = pieces[0].lowercased()
            guard let limits = sliders[key] else {
                let hint = Suggest.closest(to: key, in: Array(sliders.keys)).map { " Did you mean \"\($0)\"?" } ?? ""
                problems.append("No mask slider \"\(pieces[0])\".\(hint)")
                continue
            }
            guard seen.insert(key).inserted else {
                problems.append("\(key) is given twice.")
                continue
            }
            guard limits.contains(value) else {
                problems.append("\(key): \(CropRules.format(value)) is outside \(CropRules.format(limits.lowerBound)) to "
                                + "\(CropRules.format(limits.upperBound)).")
                continue
            }
            settings.append(MaskSetting(name: key, value: value))
        }

        let combine = p.combine ?? .add
        let title = toMask.map { "\(combine.verb) \(p.kind.title): \($0)" } ?? "New Mask: \(p.kind.title)"
        guard problems.isEmpty else { return .failure(ParameterCheck.Problems(messages: problems)) }
        return .success(Plan(kind: p.kind, name: name, toMask: toMask, combine: combine, box: box, start: start, end: end,
                             center: center, size: size, feather: feather, range: range, smoothness: smoothness,
                             person: p.person, parts: p.parts ?? [.faceSkin, .bodySkin], refine: refine, grow: grow,
                             invert: p.invert ?? false, amount: amount, settings: settings, title: title))
    }
}

// MARK: auto

public struct AutoParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var tone: Bool?
    public var whiteBalance: Bool?

    enum CodingKeys: String, CodingKey {
        case ids, selection, current, catalog, tone
        case whiteBalance = "white_balance"
    }

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                tone: Bool? = nil, whiteBalance: Bool? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.tone = tone
        self.whiteBalance = whiteBalance
    }

    public static let example = AutoParameters(ids: [1], selection: false, current: false, catalog: "Atelier Catalog",
                                               tone: true, whiteBalance: true)
    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "tone": FieldNote("Basic > Auto: Exposure, Highlights, Shadows, Whites and Blacks from each photo's own "
                          + "histogram (default true)."),
        "white_balance": FieldNote("Auto White Balance (⇧⌘U) on each photo, before the tone (default false)."),
    ]) { $1 }

    /// "Auto Tone", "Auto White Balance", or both; nil when neither is asked for.
    public var title: String? {
        let tone = self.tone ?? true, white = whiteBalance ?? false
        switch (white, tone) {
        case (true, true): return "Auto White Balance and Tone"
        case (true, false): return "White Balance: Auto"
        case (false, true): return "Auto Tone"
        case (false, false): return nil
        }
    }
}

// MARK: match_look

public enum MatchSkin: String, AgentEnum {
    /// Faces are left out of the match.
    case off
    /// Protect Skin Tones: faces keep their color and brightness (the dialog's choice when it finds faces).
    case protect
    /// Match Skin Tone: faces are matched to the reference's skin with masks.
    case match
}

public enum MatchAreas: String, AgentEnum {
    case wholePhoto = "whole_photo"
    case subject
}

public enum MatchFit: String, AgentEnum {
    /// One fit on the first photo, the same changes on the others (the dialog's Same settings).
    case same
    /// Every photo fitted on its own (Match each photo).
    case each
}

public struct MatchLookParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var reference: Int64?
    public var study: String?
    public var whiteBalance: Bool?
    public var tone: Bool?
    public var color: Bool?
    public var skin: MatchSkin?
    public var areas: MatchAreas?
    public var strength: Double?
    public var fit: MatchFit?

    enum CodingKeys: String, CodingKey {
        case ids, selection, current, catalog, reference, study
        case whiteBalance = "white_balance"
        case tone, color, skin, areas, strength, fit
    }

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                reference: Int64? = nil, study: String? = nil, whiteBalance: Bool? = nil, tone: Bool? = nil,
                color: Bool? = nil, skin: MatchSkin? = nil, areas: MatchAreas? = nil, strength: Double? = nil,
                fit: MatchFit? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.reference = reference
        self.study = study
        self.whiteBalance = whiteBalance
        self.tone = tone
        self.color = color
        self.skin = skin
        self.areas = areas
        self.strength = strength
        self.fit = fit
    }

    public static let example = MatchLookParameters(
        ids: [2], selection: false, current: false, catalog: "Atelier Catalog", reference: 1, study: "The Matrix — Portrait",
        whiteBalance: true, tone: true, color: true, skin: .protect, areas: .wholePhoto, strength: 80, fit: .same)

    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "reference": FieldNote("The catalog photo whose look to match, with its current edits. Give reference or study."),
        "study": FieldNote("A built-in color study by name: \(MatchLookRules.studyNames.joined(separator: "; ")). "
                           + "Studies give color only (Tone is off for them)."),
        "white_balance": FieldNote("Match Temp and Tint (default true)."),
        "tone": FieldNote("Match Exposure and the tone curve (default true)."),
        "color": FieldNote("Match Saturation, HSL and the grading wheels (default true)."),
        "skin": FieldNote("off, protect (default: faces keep their color) or match (faces matched to the reference's "
                          + "skin with masks; fits each photo)."),
        "areas": FieldNote("whole_photo, or subject: background to background and subject to subject with a mask "
                           + "(default subject for a portrait study, otherwise whole_photo; wide studies only take "
                           + "whole_photo)."),
        "strength": FieldNote("How much of the match to apply, percent (default 100).", minimum: 0, maximum: 100),
        "fit": FieldNote("same (default): fitted on the first photo, the same changes on the others. each: every "
                         + "photo fitted on its own (slower; always so with skin match)."),
    ]) { $1 }
}

/// The plain rules of `match_look`.
public enum MatchLookRules {
    /// The built-in studies' names, as the Match Look dialog shows them. The app checks they're
    /// the same as its own list (AtelierAppTests).
    public static let studyNames = [
        "The Matrix — Portrait", "The Matrix — Urban Night",
        "Game of Thrones — Portrait", "Game of Thrones — Winter Landscape",
        "Mad Max: Fury Road — Portrait", "Mad Max: Fury Road — Desert Action",
        "The Dark Knight — Portrait", "The Dark Knight — Urban Night",
    ]

    /// A study's index in `studyNames`, found by its name loosely: case, dashes and spacing don't
    /// matter, so "the matrix - portrait" and "Matrix Portrait" find it.
    public static func study(named text: String) -> Result<Int, ParameterCheck.Problems> {
        func key(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "the ", with: "")
                .filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(text)
        if let index = studyNames.firstIndex(where: { key($0) == wanted }) { return .success(index) }
        let hint = Suggest.closest(to: text, in: studyNames).map { " Did you mean “\($0)”?" } ?? ""
        return .failure(ParameterCheck.Problems(messages: ["No study “\(text)”.\(hint) The studies are: "
                                                           + studyNames.joined(separator: "; ") + "."]))
    }

    /// Checks the call's own fields (the app checks the reference photo and the study's areas).
    public static func check(_ p: MatchLookParameters) -> [String] {
        var problems: [String] = []
        switch (p.reference != nil, p.study != nil) {
        case (true, true): problems.append("Give reference or study, not both.")
        case (false, false): problems.append("match_look needs reference (a photo id) or study (a built-in study's name).")
        default: break
        }
        if let strength = p.strength, !strength.isFinite || !(0...100).contains(strength) {
            problems.append("strength: \(strength) is outside 0 to 100.")
        }
        if p.strength == 0 { problems.append("strength 0 changes nothing.") }
        if p.whiteBalance == false, p.tone == false, p.color == false, (p.skin ?? .protect) != .match {
            problems.append("Turn on white_balance, tone, color or skin match: there is nothing to match.")
        }
        return problems
    }
}

public extension AtelierAgentTools {
    static let crop = MCPTool(
        name: "crop", title: "Crop and straighten",
        description: "Crops, straightens, rotates or flips photos, like Develop's crop tool: lock an aspect ratio "
            + "(the largest crop that fits, kept around its center), set a box, straighten by an angle (the crop "
            + "shrinks to stay on the photo), turn a quarter or flip. Steps run in the order reset, rotate, flip, angle, "
            + "aspect, box. One change; undo_change undoes it.",
        inputSchema: ParameterSchema.of(CropParameters.self).json, readOnly: false)

    static let addMask = MCPTool(
        name: "add_mask", title: "Add a mask",
        description: "Adds a mask to photos, or a part to an existing mask: Select Subject, Select Background, Select Object (a box), Select "
            + "People (parts, one person or everyone), Linear Gradient, Radial Gradient or Luminance Range, with the new "
            + "mask's sliders. Positions are fractions of the photo as get_preview shows it. Subject, object and people "
            + "are found by Atelier when the photo renders; check the result with get_preview. One change; "
            + "undo_change undoes it.",
        inputSchema: ParameterSchema.of(AddMaskParameters.self).json, readOnly: false)

    static let auto = MCPTool(
        name: "auto", title: "Auto tone and white balance",
        description: "Basic > Auto on photos: Exposure, Highlights, Shadows, Whites and Blacks from each photo's own "
            + "pixels, and with white_balance Auto White Balance first. Atelier measures each photo in the background "
            + "(about a second a photo; the person sees progress and can cancel), then makes one change; undo_change "
            + "undoes it.",
        inputSchema: ParameterSchema.of(AutoParameters.self).json, readOnly: false)

    static let matchLook = MCPTool(
        name: "match_look", title: "Match Look to a reference",
        description: "Photo > Match Look to Reference: fits photos' white balance, tone and color to a reference, a "
            + "catalog photo or a built-in color study, as the Match Look dialog does. Atelier fits in the background "
            + "(a few seconds a photo with fit each; the person sees progress and can cancel), then makes one change; "
            + "undo_change undoes it.",
        inputSchema: ParameterSchema.of(MatchLookParameters.self).json, readOnly: false)

    /// The Edit tools that measure photos in the background before they change anything. They
    /// run on their own, never inside another call.
    static let measuringTools = [auto, matchLook]
}
