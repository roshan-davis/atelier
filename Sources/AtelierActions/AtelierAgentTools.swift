import AgentActions
import AgentMCP
import Foundation

// Atelier's typed write tools for agents (AT-050c, the Organize profile). Their parameters are
// Swift types, so the schemas agents see are generated from the code, and calls are checked
// with `ParameterCheck` before anything runs. The app runs them (Agents/AgentOrganizeTools.swift).

/// The photos a write names: exactly one of `ids`, `selection` or `current`. `catalog`, when
/// given, must be the catalog Atelier has open, so ids from another catalog are refused.
public protocol PhotoTargeting {
    var ids: [Int64]? { get }
    var selection: Bool? { get }
    var current: Bool? { get }
    var catalog: String? { get }
}

public enum PhotoTargetNotes {
    public static let notes: [String: FieldNote] = [
        "ids": FieldNote("Photo ids (from search_photos or get_context). Give ids, selection or current."),
        "selection": FieldNote("true: the photos selected in Atelier now (the open photo outside the grid)."),
        "current": FieldNote("true: the photo in front (open in Loupe or Develop, or focused in the grid)."),
        "catalog": FieldNote("The catalog name the ids came from, as replies show it. Optional; a mismatch is refused."),
    ]

    /// The same fields for a hand-written schema (command_run).
    public static var properties: [String: JSONValue] {
        [
            "ids": .object(["type": .string("array"), "items": .object(["type": .string("integer")]),
                            "description": .string(notes["ids"]!.summary)]),
            "selection": .object(["type": .string("boolean"), "description": .string(notes["selection"]!.summary)]),
            "current": .object(["type": .string("boolean"), "description": .string(notes["current"]!.summary)]),
            "catalog": .object(["type": .string("string"), "description": .string(notes["catalog"]!.summary)]),
        ]
    }
}

public enum ModeChoice: String, AgentEnum {
    case grid, loupe, develop
}

/// A color label to set, or none to clear it.
public enum LabelSetting: String, AgentEnum {
    case red, yellow, green, blue, purple, none
}

public struct ShowParameters: ActionParameters, Hashable {
    public var ids: [Int64]
    public var mode: ModeChoice?
    public var reveal: Bool?
    public var catalog: String?

    public init(ids: [Int64], mode: ModeChoice? = nil, reveal: Bool? = nil, catalog: String? = nil) {
        self.ids = ids
        self.mode = mode
        self.reveal = reveal
        self.catalog = catalog
    }

    public static let example = ShowParameters(ids: [1], mode: .grid, reveal: true, catalog: "Atelier Catalog")
    public static let fieldNotes: [String: FieldNote] = [
        "ids": FieldNote("The photos to select; the first one is put in front."),
        "mode": FieldNote("Where to show them (default: stay in the current view; grid when in HDR)."),
        "reveal": FieldNote("true: if some aren't in the current source or filter, switch to All Photographs and "
                            + "clear the filter so they show. Without it, the reply says which are hidden."),
        "catalog": PhotoTargetNotes.notes["catalog"]!,
    ]
}

public struct SetMetadataParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var rating: Int?
    public var flag: FlagChoice?
    public var label: LabelSetting?
    public var addKeywords: [String]?
    public var removeKeywords: [String]?
    public var title: String?
    public var caption: String?
    /// A note to add to each photo's notes (AT-058), shown as written by the chat app.
    public var addNote: String?

    enum CodingKeys: String, CodingKey {
        case ids, selection, current, catalog, rating, flag, label, title, caption
        case addKeywords = "add_keywords"
        case removeKeywords = "remove_keywords"
        case addNote = "add_note"
    }

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                rating: Int? = nil, flag: FlagChoice? = nil, label: LabelSetting? = nil, addKeywords: [String]? = nil,
                removeKeywords: [String]? = nil, title: String? = nil, caption: String? = nil, addNote: String? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.rating = rating
        self.flag = flag
        self.label = label
        self.addKeywords = addKeywords
        self.removeKeywords = removeKeywords
        self.title = title
        self.caption = caption
        self.addNote = addNote
    }

    public static let example = SetMetadataParameters(
        ids: [1], selection: false, current: false, catalog: "Atelier Catalog", rating: 3, flag: .picked, label: .red,
        addKeywords: ["sunset"], removeKeywords: ["test"], title: "Title", caption: "Caption",
        addNote: "Eyes closed in the next frame")
    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "rating": FieldNote("Stars, 0 to clear the rating.", minimum: 0, maximum: 5),
        "flag": FieldNote("Pick, reject or remove the flag."),
        "label": FieldNote("The color label to set; none clears it."),
        "add_keywords": FieldNote("Keywords to add (kept if the photo already has them)."),
        "remove_keywords": FieldNote("Keywords to take off."),
        "title": FieldNote("The title; an empty string clears it."),
        "caption": FieldNote("The caption; an empty string clears it."),
        "add_note": FieldNote("A note to add to each photo's sticky notes, signed with your app's name. Plain text with "
                              + "\"- \" bullets, \"1. \" numbers, \"- [ ] \" checkboxes, **bold** and *italic*. Notes are "
                              + "private to Atelier: never put in the caption or exported."),
    ]) { $1 }

    /// True when the call names nothing to change.
    public var changesNothing: Bool {
        rating == nil && flag == nil && label == nil && (addKeywords ?? []).isEmpty && (removeKeywords ?? []).isEmpty
            && title == nil && caption == nil
            && (addNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct OrganizeParameters: ActionParameters, Hashable, PhotoTargeting {
    public var ids: [Int64]?
    public var selection: Bool?
    public var current: Bool?
    public var catalog: String?
    public var addToCollection: Int64?
    public var newCollection: String?
    public var virtualCopy: Bool?

    enum CodingKeys: String, CodingKey {
        case ids, selection, current, catalog
        case addToCollection = "add_to_collection"
        case newCollection = "new_collection"
        case virtualCopy = "virtual_copy"
    }

    public init(ids: [Int64]? = nil, selection: Bool? = nil, current: Bool? = nil, catalog: String? = nil,
                addToCollection: Int64? = nil, newCollection: String? = nil, virtualCopy: Bool? = nil) {
        self.ids = ids
        self.selection = selection
        self.current = current
        self.catalog = catalog
        self.addToCollection = addToCollection
        self.newCollection = newCollection
        self.virtualCopy = virtualCopy
    }

    public static let example = OrganizeParameters(ids: [1], selection: false, current: false, catalog: "Atelier Catalog",
                                                   addToCollection: 1, newCollection: "Best of", virtualCopy: true)
    public static let fieldNotes: [String: FieldNote] = PhotoTargetNotes.notes.merging([
        "add_to_collection": FieldNote("Add the photos to this collection (ids from list_items kind collections)."),
        "new_collection": FieldNote("Make a collection with this name and add the photos to it."),
        "virtual_copy": FieldNote("true: add a virtual copy of each photo, with its own Develop settings."),
    ]) { $1 }
}

public struct UndoChangeParameters: ActionParameters, Hashable {
    public var change: String
    public init(change: String) { self.change = change }
    public static let example = UndoChangeParameters(change: "c-1")
    public static let fieldNotes = ["change": FieldNote("The change id a write returned, such as \"c-17\".")]
}

/// The typed tools and the rules for which profile Atelier's commands need.
public enum AtelierAgentTools {
    /// The highest profile whose commands agents can run in this version (AT-050d: Edit).
    /// AT-050e raises it to Everything.
    public static let runCeiling = AgentProfile.edit

    /// Which profile an Atelier edit command needs: Develop changes need Edit, library changes
    /// (ratings, flags, labels, collections, virtual copies) need Organize.
    public static func editProfile(_ action: ActionDescriptor) -> AgentProfile {
        if action.id.rawValue.hasPrefix("develop.") { return .edit }
        return developEditsOutsideDevelop.contains(action.id) ? .edit : .organize
    }

    /// Photo menu commands that change Develop settings.
    static let developEditsOutsideDevelop: Set<ActionID> = [AtelierAction.resetSettings.id, AtelierAction.matchLook.id]

    public static let show = MCPTool(
        name: "show", title: "Show photos",
        description: "Selects photos in Atelier's own window and puts the first in front, optionally switching to Grid, Loupe "
            + "or Develop. Changes only Atelier's window; it doesn't show the photo in a chat (use get_preview for that).",
        inputSchema: ParameterSchema.of(ShowParameters.self).json, readOnly: false, idempotent: true)

    public static let setMetadata = MCPTool(
        name: "set_metadata", title: "Rate, flag, label and describe",
        description: "Sets the rating, flag, color label, keywords, title or caption of photos (a RAW's hidden JPEG follows "
            + "it), or adds a note to them. One call is one change you can undo with undo_change; Atelier shows it with an Undo button. Changing "
            + "more photos than the person allows at once asks them first.",
        inputSchema: ParameterSchema.of(SetMetadataParameters.self).json, readOnly: false)

    public static let organize = MCPTool(
        name: "organize", title: "Collections and virtual copies",
        description: "Adds photos to a collection or a new one, or makes virtual copies. One call is one change; collection "
            + "changes can be undone with undo_change.",
        inputSchema: ParameterSchema.of(OrganizeParameters.self).json, readOnly: false)

    public static let undoChange = MCPTool(
        name: "undo_change", title: "Undo your change",
        description: "Undoes one of your own changes by its id. It works only while that change is still the latest on those "
            + "photos, so it never overwrites the person's later work.",
        inputSchema: ParameterSchema.of(UndoChangeParameters.self).json, readOnly: false)

    public static let commandRun = CommandRunTool.tool(
        targetProperties: PhotoTargetNotes.properties,
        description: "Commands that act on photos take ids, selection or current; without them they use the selection. "
            + "Develop commands without photos act on the photo open in Develop. Exports and other apps arrive in a later "
            + "version.")

    /// The write tools the Organize profile adds.
    public static let organizeTools = [show, setMetadata, organize, undoChange, commandRun]

    /// Every typed parameter type, for the schema check in tests.
    public static let parameterSchemas: [String: ParameterSchema] = [
        show.name: .of(ShowParameters.self),
        setMetadata.name: .of(SetMetadataParameters.self),
        organize.name: .of(OrganizeParameters.self),
        undoChange.name: .of(UndoChangeParameters.self),
        getSkill.name: .of(GetSkillParameters.self),
    ].merging(developParameterSchemas) { $1 }
}
