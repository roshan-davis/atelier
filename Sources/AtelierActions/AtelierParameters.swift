import AgentActions
import Foundation

// Parameter types for Atelier's actions. They use their own small enums so this target builds
// without AtelierCore (and the catalog can be generated anywhere); the app maps them to its types.

public extension TargetKind {
    /// Photo ids in the catalog (Int64). Resolved from the selection when the person runs the
    /// action: the open photo, or the grid selection.
    static let photos = TargetKind("photos")
}

public struct RatingParameters: ActionParameters, Hashable {
    public var stars: Int
    public init(stars: Int) { self.stars = stars }
    public static let example = RatingParameters(stars: 3)
    public static let fieldNotes = ["stars": FieldNote("Stars, 0 to clear the rating.", minimum: 0, maximum: 5)]
}

public enum FlagChoice: String, AgentEnum {
    case picked, rejected, unflagged
}

public struct FlagParameters: ActionParameters, Hashable {
    public var flag: FlagChoice
    public init(flag: FlagChoice) { self.flag = flag }
    public static let example = FlagParameters(flag: .picked)
}

public enum LabelChoice: String, AgentEnum {
    case red, yellow, green, blue, purple
}

public struct LabelParameters: ActionParameters, Hashable {
    public var label: LabelChoice
    public init(label: LabelChoice) { self.label = label }
    public static let example = LabelParameters(label: .red)
    public static let fieldNotes = ["label": FieldNote("Turns the label on, or off if the photos already have it.")]
}

/// The photo menu's zoom levels.
public enum ZoomChoice: String, AgentEnum {
    case fit, fill
    case percent100 = "100%"
    case percent200 = "200%"
}

public struct ZoomParameters: ActionParameters, Hashable {
    public var level: ZoomChoice
    public init(level: ZoomChoice) { self.level = level }
    public static let example = ZoomParameters(level: .fit)
}

public enum CompareChoice: String, AgentEnum {
    case off, sideBySide, slider
}

public struct CompareParameters: ActionParameters, Hashable {
    public var mode: CompareChoice
    public init(mode: CompareChoice) { self.mode = mode }
    public static let example = CompareParameters(mode: .sideBySide)
}

public enum PrivacyChoice: String, AgentEnum {
    case hidden, shown, only
}

public struct PrivacyParameters: ActionParameters, Hashable {
    public var visibility: PrivacyChoice
    public init(visibility: PrivacyChoice) { self.visibility = visibility }
    public static let example = PrivacyParameters(visibility: .hidden)
}

public struct PresetParameters: ActionParameters, Hashable {
    public var preset: UUID
    public init(preset: UUID) { self.preset = preset }
    public static let example = PresetParameters(preset: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    public static let fieldNotes = ["preset": FieldNote("A Develop preset's id.")]
}

public struct CollectionParameters: ActionParameters, Hashable {
    public var collection: Int64
    public init(collection: Int64) { self.collection = collection }
    public static let example = CollectionParameters(collection: 1)
    public static let fieldNotes = ["collection": FieldNote("A collection's id.")]
}

public struct LocationParameters: ActionParameters, Hashable {
    public var location: Int64
    public init(location: Int64) { self.location = location }
    public static let example = LocationParameters(location: 1)
    public static let fieldNotes = ["location": FieldNote("A storage location's id (Settings > Storage).")]
}

public struct EditorParameters: ActionParameters, Hashable {
    public var editor: String
    public init(editor: String) { self.editor = editor }
    public static let example = EditorParameters(editor: "/Applications/Example.app")
    public static let fieldNotes = ["editor": FieldNote("The path of an app set up in Settings > Edit In.")]
}

public struct RecipeParameters: ActionParameters, Hashable {
    public var recipe: String
    public init(recipe: String) { self.recipe = recipe }
    public static let example = RecipeParameters(recipe: "remove-object")
    public static let fieldNotes = ["recipe": FieldNote("An AI recipe's id, as in the Photo menu's AI items.")]
}
