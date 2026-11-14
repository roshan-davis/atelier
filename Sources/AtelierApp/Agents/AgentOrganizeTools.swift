import AgentActions
import AgentMCP
import AppKit
import AtelierActions
import AtelierCore
import Foundation

/// An agent change to photos, with each photo's state before and after: its library fields
/// (Organize tools) or its Develop settings (Edit tools).
typealias PhotoChangeLog = AgentChangeLog<Int64, PhotoState>

/// What a change changed on one photo, so undo can tell whether it's still the latest: its
/// library fields, its Develop settings, or both (an atomic batch can change both).
struct PhotoState: Equatable, Sendable {
    var library: LibraryState?
    var develop: DevelopSettings?

    enum Kind { case library, develop }

    static func library(_ state: LibraryState) -> PhotoState { PhotoState(library: state) }
    static func develop(_ settings: DevelopSettings) -> PhotoState { PhotoState(develop: settings) }

    /// These fields, plus any of `other`'s this one doesn't have yet.
    func filling(from other: PhotoState) -> PhotoState {
        PhotoState(library: library ?? other.library, develop: develop ?? other.develop)
    }
}

/// The line Atelier shows at the bottom of the photo after an agent changed something, with
/// Undo while the change can still be undone.
struct AgentNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// The change Undo undoes; nil for a plain notice.
    let changeID: String?
}

/// The Organize profile's tools (AT-050c): show, set_metadata, organize, undo_change and
/// command_run for library and cull commands. They run on the main thread, like the menus.
/// Every write names its photos, is one change with an id the agent can undo, shows a notice
/// with Undo in the window, and asks the person first when it changes many photos.
extension AgentServer {
    /// What replies call the open catalog, so ids from another catalog can be refused.
    var catalogName: String {
        model?.catalog.packageURL?.deletingPathExtension().lastPathComponent ?? "Atelier Catalog"
    }

    /// Runs a write tool, or returns nil when `tool` isn't one.
    func callWrite(_ tool: String, _ arguments: [String: JSONValue], client: AgentClient,
                   profile: AgentProfile) -> MCPToolResult? {
        if AtelierAgentTools.editTools.contains(where: { $0.name == tool }) {
            return callDevelop(tool, arguments, client: client, profile: profile)
        }
        if tool == AtelierAgentTools.commandBatch.name {
            return callBatch(arguments, client: client, profile: profile)
        }
        guard AtelierAgentTools.organizeTools.contains(where: { $0.name == tool }) else { return nil }
        guard profile >= .organize else {
            return .error("\(tool) needs the Organize profile. The person can change that in Atelier > Settings… > Agents.")
        }
        guard let model else { return .error("\(Self.appName) is closing.") }
        do {
            switch tool {
            case AtelierAgentTools.show.name:
                return try show(try decode(ShowParameters.self, arguments), model)
            case AtelierAgentTools.setMetadata.name:
                return try setMetadata(try decode(SetMetadataParameters.self, arguments), client, model)
            case AtelierAgentTools.organize.name:
                return try organize(try decode(OrganizeParameters.self, arguments), client, model)
            case AtelierAgentTools.undoChange.name:
                return try undoChange(try decode(UndoChangeParameters.self, arguments).change, client, model)
            case AtelierAgentTools.commandRun.name:
                return try commandRun(arguments, client, profile, model)
            default:
                return nil
            }
        } catch let problem as ArgumentProblem {
            return .error(problem.message)
        } catch {
            return .error("Atelier couldn't make the change: \(error.localizedDescription)")
        }
    }

    func decode<P: ActionParameters>(_ type: P.Type, _ arguments: [String: JSONValue]) throws -> P {
        switch ParameterCheck.decode(P.self, from: arguments) {
        case .failure(let problems): throw ArgumentProblem(problems.text)
        case .success(let parameters): return parameters
        }
    }

    // MARK: show

    private func show(_ parameters: ShowParameters, _ model: LibraryModel) throws -> MCPToolResult {
        try checkCatalog(parameters.catalog)
        let ids = try publicPhotos(unique(parameters.ids), model, named: true)
        let visible = Set(model.rows.map(\.id))
        let hidden = ids.filter { !visible.contains($0) }
        var revealed = false
        if !hidden.isEmpty, parameters.reveal == true {
            model.sidebarSelection = .all
            model.filter = model.filter.cleared
            revealed = true
        }
        if model.mode == .hdr, parameters.mode == nil { model.mode = .grid }
        model.selection = Set(ids)
        model.focusedID = ids.first
        switch parameters.mode {
        case .grid: model.mode = .grid
        case .loupe: model.openLoupe()
        case .develop: model.openDevelop()
        case nil: break
        }
        var reply: [String: JSONValue] = [
            "catalog": .string(catalogName),
            "selected": .array(ids.prefix(200).map { .int(Int($0)) }),
            "selected_count": .int(ids.count),
            "in_front": .int(Int(ids[0])),
            "mode": .string(modeName(model.mode)),
        ]
        if revealed {
            reply["note"] = .string("Switched to All Photographs and cleared the filter so they all show.")
        } else if !hidden.isEmpty {
            reply["hidden_by_view"] = .array(hidden.prefix(200).map { .int(Int($0)) })
            reply["note"] = .string("\(hidden.count) of them aren't in the current source or filter, so the grid doesn't show "
                                    + "them. Call show again with reveal: true to switch to All Photographs.")
        }
        return .json(.object(reply))
    }

    // MARK: set_metadata

    private func setMetadata(_ parameters: SetMetadataParameters, _ client: AgentClient,
                             _ model: LibraryModel) throws -> MCPToolResult {
        guard !parameters.changesNothing else {
            throw ArgumentProblem("set_metadata needs something to set: rating, flag, label, add_keywords, "
                                  + "remove_keywords, title, caption or add_note.")
        }
        let title = Self.metadataTitle(parameters)
        return try write(parameters, title: title, client, model) { named, affected in
            let catalog = model.catalog
            if let rating = parameters.rating { try catalog.setRating(rating, for: affected) }
            if let flag = parameters.flag { try catalog.setFlag(Flag(flag), for: affected) }
            if let label = parameters.label { try catalog.setColorLabel(ColorLabel(label), for: affected) }
            if let names = parameters.addKeywords, !names.isEmpty { try catalog.addKeywords(names, to: affected) }
            if let names = parameters.removeKeywords, !names.isEmpty { try catalog.removeKeywords(names, from: affected) }
            if parameters.title != nil || parameters.caption != nil {
                try catalog.setTitle(parameters.title, orCaption: parameters.caption, for: affected)
            }
            // Notes stay on the photo named, not on a RAW's hidden JPEG.
            if let note = parameters.addNote {
                _ = try catalog.addNote(note, source: .agent, appName: client.name, to: named)
            }
        }
    }

    /// "Rate 3 stars, flag as picked": the change's name in the notice and the activity log.
    static func metadataTitle(_ parameters: SetMetadataParameters) -> String {
        var parts: [String] = []
        if let rating = parameters.rating {
            parts.append(rating == 0 ? "clear the rating" : "rate \(rating) star\(rating == 1 ? "" : "s")")
        }
        switch parameters.flag {
        case .picked: parts.append("flag as picked")
        case .rejected: parts.append("flag as rejected")
        case .unflagged: parts.append("remove the flag")
        case nil: break
        }
        if let label = parameters.label {
            parts.append(label == .none ? "clear the color label" : "label \(label.rawValue)")
        }
        if let names = parameters.addKeywords, !names.isEmpty { parts.append("add keywords \(names.joined(separator: ", "))") }
        if let names = parameters.removeKeywords, !names.isEmpty {
            parts.append("remove keywords \(names.joined(separator: ", "))")
        }
        if parameters.title != nil { parts.append("set the title") }
        if parameters.caption != nil { parts.append("set the caption") }
        if let note = parameters.addNote, !NoteText.cleaned(note).isEmpty { parts.append("add a note") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: organize

    private func organize(_ parameters: OrganizeParameters, _ client: AgentClient,
                          _ model: LibraryModel) throws -> MCPToolResult {
        let asked = [parameters.addToCollection != nil, parameters.newCollection != nil, parameters.virtualCopy == true]
        guard asked.filter({ $0 }).count == 1 else {
            throw ArgumentProblem("organize does one thing per call: give add_to_collection, new_collection or "
                                  + "virtual_copy: true.")
        }
        if let collectionID = parameters.addToCollection {
            let collections = try model.catalog.writer.read { db in try Catalog.fetchCollections(db, privacy: .hidden) }
            guard let collection = collections.first(where: { $0.id == collectionID }) else {
                throw ArgumentProblem("No collection with id \(collectionID). Use list_items with kind collections.")
            }
            return try write(parameters, title: "Add to “\(collection.name)”", client, model) { _, affected in
                try model.catalog.addAssets(affected, toCollection: collectionID)
            }
        }
        if let name = parameters.newCollection {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ArgumentProblem("new_collection needs a name.") }
            var created: Int64?
            var result = try write(parameters, title: "Add to new collection “\(trimmed)”", client, model) { _, affected in
                let collection = try model.catalog.createCollection(named: trimmed)
                guard let id = collection.id else { return }
                created = id
                try model.catalog.addAssets(affected, toCollection: id)
            }
            if let created, case .object(var members)? = result.structured {
                members["collection_id"] = .int(Int(created))
                members["note"] = .string("Undoing this change takes the photos out again; the collection itself stays.")
                result = .json(.object(members))
            }
            return result
        }
        // Virtual copies: new photos, which only the person removes (Photo > Remove Virtual Copy…).
        var copies: [Int64] = []
        var result = try write(parameters, title: "Create virtual copies", client, model,
                               cantUndo: "it made new photos. The person removes them with Photo > Remove Virtual Copy….") { named, _ in
            let before = Set(model.selection)
            model.withTargets(named) { model.createVirtualCopies() }
            copies = model.selection.subtracting(before).sorted()
        }
        if case .object(var members)? = result.structured {
            members["copies"] = .array(copies.map { .int(Int($0)) })
            result = .json(.object(members))
        }
        return result
    }

    // MARK: undo_change

    private func undoChange(_ id: String, _ client: AgentClient, _ model: LibraryModel) throws -> MCPToolResult {
        switch undo(id, by: client.id, model) {
        case .failure(let refusal):
            return .error(refusal.message)
        case .success(let change):
            return .json(.object([
                "catalog": .string(catalogName),
                "undone": .string(change.id),
                "did": .string(change.title),
                "photos": .int(change.after.count),
            ]))
        }
    }

    /// Undoes a change for an agent (`clientID`) or for the person (nil, the notice's Undo).
    private func undo(_ id: String, by clientID: String?, _ model: LibraryModel) -> Result<PhotoChangeLog.Change, AgentUndoRefusal> {
        guard let change = changes.change(id) else { return .failure(.unknown(id)) }
        let current = (try? states(shapedLike: change.after, model)) ?? [:]
        switch changes.undoPlan(id, clientID: clientID, current: current) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let states):
            var restored = true
            let library = states.compactMapValues(\.library)
            if !library.isEmpty {
                restored = model.performEdit(on: Array(library.keys)) { try $0.restoreLibraryStates(library) }
            }
            let develop = states.compactMapValues(\.develop)
            if restored, !develop.isEmpty {
                do {
                    try model.develop.apply(each: develop, step: "Undo \(change.title) (\(change.clientName))")
                } catch {
                    model.status = error.localizedDescription
                    restored = false
                }
            }
            guard restored else { return .failure(.cantUndo(id, reason: model.status ?? "the catalog refused the change.")) }
            changes.markUndone(id)
            let who = clientID == nil ? "" : "\(change.clientName) "
            announce("\(who)undid: \(change.title) (\(Self.count(change.after.count)))", change: nil)
            log(change.clientName, .call, "Undid \(change.id): \(change.title)")
            return .success(change)
        }
    }

    /// The notice's Undo button.
    func undoFromWindow(_ changeID: String) {
        guard let model else { return }
        if case .failure(let refusal) = undo(changeID, by: nil, model) {
            announce(refusal.message, change: nil)
        }
    }

    // MARK: command_run

    private struct CommandTargets: PhotoTargeting {
        var ids: [Int64]?
        var selection: Bool?
        var current: Bool?
        var catalog: String?
        var given: Bool { ids != nil || selection != nil || current != nil }
    }

    private func commandRun(_ arguments: [String: JSONValue], _ client: AgentClient, _ profile: AgentProfile,
                            _ model: LibraryModel) throws -> MCPToolResult {
        var rest = arguments
        var targets = CommandTargets()
        if let list = rest.removeValue(forKey: "ids") {
            guard let values = list.arrayValue, values.allSatisfy({ $0.intValue != nil }) else {
                throw ArgumentProblem("\"ids\" must be a list of photo ids.")
            }
            targets.ids = values.compactMap { $0.intValue }.map { Int64($0) }
        }
        targets.selection = rest.removeValue(forKey: "selection")?.boolValue
        targets.current = rest.removeValue(forKey: "current")?.boolValue
        targets.catalog = rest.removeValue(forKey: "catalog")?.stringValue
        for key in rest.keys.sorted() where key != "id" && key != "parameters" {
            let names = ["id", "parameters", "ids", "selection", "current", "catalog"]
            let hint = Suggest.closest(to: key, in: names).map { " Did you mean \"\($0)\"?" } ?? ""
            throw ArgumentProblem("Unknown argument \"\(key)\" for command_run.\(hint)")
        }
        let checked: CommandRunTool.Checked
        switch CommandRunTool.check(rest, catalog: AtelierAction.catalog, profile: profile,
                                    ceiling: AtelierAgentTools.runCeiling, editProfile: AtelierAgentTools.editProfile) {
        case .failure(let problems): throw ArgumentProblem(problems.text)
        case .success(let value): checked = value
        }
        let action = checked.action
        let registry = model.actions
        if !targets.given, action.targets == .photos { targets.selection = true }

        func run(_ named: [Int64]?) throws -> Bool {
            do {
                return try registry.run(action.id, json: checked.parameters, targets: named)
            } catch {
                throw ArgumentProblem("\(action.id): the parameters don't fit: \(error)")
            }
        }

        // Develop commands change Develop settings: recorded as such, so undo_change restores them.
        let developEdit = action.kind == .edit && AtelierAgentTools.editProfile(action) == .edit
        if developEdit, action.targets != .photos {
            // Commands of the Develop menu act on the photo open in Develop.
            guard !targets.given else {
                throw ArgumentProblem("\(action.id) acts on the photo open in Develop; leave out ids, selection and current.")
            }
            guard model.mode == .develop, let open = model.develop.assetID else {
                throw ArgumentProblem("\(action.title) works on the photo open in Develop. Open one first with show "
                                      + "(mode: develop).")
            }
            targets.ids = [open]
        }
        if action.kind == .edit, action.targets == .photos || developEdit {
            var applied = true
            let isCopy = action.id == AtelierAction.createVirtualCopy.id
            return try write(targets, title: action.title, client, model, kind: developEdit ? .develop : .library,
                             cantUndo: isCopy ? "it made new photos. The person removes them with Photo > Remove Virtual Copy…." : nil,
                             extra: ["command": .string(action.id.rawValue)]) { named, _ in
                applied = try run(action.targets == .photos ? named : nil)
                if !applied { throw ArgumentProblem("\(action.title) doesn't apply right now (\(action.place)).") }
            }
        }
        var named: [Int64]?
        if action.targets == .photos { named = try resolve(targets, model) }
        else { try checkCatalog(targets.catalog) }
        let applied = try run(named)
        var reply: [String: JSONValue] = [
            "catalog": .string(catalogName),
            "command": .string(action.id.rawValue),
            "applied": .bool(applied),
            "mode": .string(modeName(model.mode)),
        ]
        if let named { reply["photos"] = .array(named.prefix(200).map { .int(Int($0)) }) }
        if !applied { reply["note"] = .string("\(action.title) doesn't apply right now (\(action.place)).") }
        return .json(.object(reply))
    }

    // MARK: The guard every write goes through

    /// Resolves the photos once, asks the person first above Settings > Agents' limit, checks
    /// again after asking, makes the change, records it with each photo's state before and after,
    /// and shows the notice. `apply` gets the named photos and the ones that change with them
    /// (a RAW's hidden JPEG).
    func write(_ targets: PhotoTargeting, title: String, _ client: AgentClient, _ model: LibraryModel,
               kind: PhotoState.Kind = .library, cantUndo: String? = nil, extra: [String: JSONValue] = [:],
               apply: (_ named: [Int64], _ affected: [Int64]) throws -> Void) throws -> MCPToolResult {
        let named = try resolve(targets, model)
        // A RAW's hidden JPEG follows it in the library; Develop settings are each photo's own.
        let affected = kind == .library ? unique(model.pairIDs(named)) : named
        let limit = AgentSettings.confirmAbove
        // In an atomic batch, asking counts the whole batch's photos, and asks once.
        let batch = batchRun?.atomic == true ? batchRun : nil
        let counted = batch.map { $0.photos.union(affected).count } ?? affected.count
        if limit > 0, counted > limit, batch?.confirmed != true {
            let looked = try states(kind, affected, model)
            guard AgentConfirm.ask(client: client.name, title: batch?.label ?? title, count: counted) else {
                return .error("The person said no in Atelier: \(batch?.label ?? title) for \(Self.count(counted)) wasn't made.")
            }
            batch?.confirmed = true
            // Asking took time: the photos must be as they were when the person was asked.
            let now = try states(kind, affected, model)
            let stillPublic = try model.catalog.privatePhotoIDs(among: affected).isEmpty
            guard now == looked, now.count == affected.count, stillPublic else {
                return .error("Target changed: some of these photos were edited or removed while Atelier asked. Nothing "
                              + "was changed. Look again with search_photos and try again.")
            }
        }
        let before = try states(kind, affected, model)
        batch?.remember(before, named: named)
        switch kind {
        case .library:
            var failure: Error?
            let made = model.performEdit(on: affected) { _ in
                do { try apply(named, affected) } catch { failure = error; throw error }
            }
            if let failure { throw failure }
            guard made else { return .error("Atelier couldn't make the change: \(model.status ?? "the catalog refused it").") }
        case .develop:
            try apply(named, affected)
            // A command's own edit becomes its history step now, so its state after is what's saved.
            model.develop.flushSave()
        }
        if batch != nil {
            // Recorded once, for the whole batch, when it ends.
            var reply: [String: JSONValue] = ["did": .string(title), "photos": .int(named.count),
                                              "ids": .array(named.prefix(200).map { .int(Int($0)) })]
            for (key, value) in extra { reply[key] = value }
            return .json(.object(reply))
        }
        let after = try states(kind, affected, model)
        let change = changes.record(clientID: client.id, clientName: client.name, title: title, targets: named,
                                    before: before, after: after, cantUndo: cantUndo)
        let unchanged = affected.filter { before[$0] == after[$0] }.count
        announce("\(client.name): \(title) (\(Self.count(named.count)))", change: cantUndo == nil ? change.id : nil)
        log(client.name, .call, "\(change.id): \(title), \(Self.count(named.count))")
        var reply: [String: JSONValue] = [
            "change": .string(change.id),
            "catalog": .string(catalogName),
            "did": .string(title),
            "photos": .int(named.count),
            "ids": .array(named.prefix(200).map { .int(Int($0)) }),
        ]
        if affected.count > named.count { reply["hidden_jpegs_too"] = .int(affected.count - named.count) }
        if unchanged > 0 { reply["already_so"] = .int(unchanged) }
        reply["undo"] = .string(cantUndo.map { "Can't be undone with undo_change: \($0)" }
                                ?? "undo_change with change \"\(change.id)\" while it is still the latest change on them.")
        for (key, value) in extra { reply[key] = value }
        return .json(.object(reply))
    }

    /// Each photo's state of the kind a change touches.
    func states(_ kind: PhotoState.Kind, _ ids: [Int64], _ model: LibraryModel) throws -> [Int64: PhotoState] {
        switch kind {
        case .library: return try model.catalog.libraryStates(for: ids).mapValues { .library($0) }
        case .develop: return try model.develop.currentSettings(for: ids).mapValues { .develop($0) }
        }
    }

    /// Each photo's state with the same fields as `shape` (a change's after states), for undo.
    func states(shapedLike shape: [Int64: PhotoState], _ model: LibraryModel) throws -> [Int64: PhotoState] {
        let libraryIDs = shape.filter { $0.value.library != nil }.map(\.key)
        let developIDs = shape.filter { $0.value.develop != nil }.map(\.key)
        let library = libraryIDs.isEmpty ? [:] : try model.catalog.libraryStates(for: libraryIDs)
        let develop = developIDs.isEmpty ? [:] : try model.develop.currentSettings(for: developIDs)
        var result: [Int64: PhotoState] = [:]
        for id in shape.keys {
            let state = PhotoState(library: library[id], develop: develop[id])
            // A photo whose state can't be read is left out, so undo reports it gone.
            if (shape[id]?.library == nil || state.library != nil) && (shape[id]?.develop == nil || state.develop != nil) {
                result[id] = state
            }
        }
        return result
    }

    /// The photos a call names, resolved once: they exist, aren't private, and come from the open
    /// catalog. The selection is read now, so a later change of selection can't change the call.
    func resolve(_ targets: PhotoTargeting, _ model: LibraryModel) throws -> [Int64] {
        try checkCatalog(targets.catalog)
        let ways = [targets.ids != nil, targets.selection == true, targets.current == true].filter { $0 }.count
        guard ways == 1 else {
            throw ArgumentProblem("Name the photos with exactly one of ids, selection: true or current: true.")
        }
        if let ids = targets.ids { return try publicPhotos(unique(ids), model, named: true) }
        if targets.selection == true {
            let ids = try publicPhotos(model.targetIDs, model, named: false)
            guard !ids.isEmpty else { throw ArgumentProblem("Nothing is selected in Atelier.") }
            return ids
        }
        let ids = try publicPhotos(model.focusedID.map { [$0] } ?? [], model, named: false)
        guard !ids.isEmpty else { throw ArgumentProblem("No photo is in front in Atelier.") }
        return ids
    }

    /// Photos agents may change. Named ids that are missing or private are refused (a private
    /// photo reads as missing); a selection quietly leaves private photos out.
    private func publicPhotos(_ ids: [Int64], _ model: LibraryModel, named: Bool) throws -> [Int64] {
        guard !ids.isEmpty else { throw ArgumentProblem("ids is empty: give at least one photo id.") }
        let hidden = try model.catalog.privatePhotoIDs(among: ids)
        let existing = try model.catalog.libraryStates(for: ids)
        let missing = ids.filter { hidden.contains($0) || existing[$0] == nil }
        if named, let first = missing.first {
            let more = missing.count > 1 ? " (and \(missing.count - 1) more)" : ""
            throw ArgumentProblem("\(AgentLookTools.noPhoto(first))\(more) Nothing was changed.")
        }
        return ids.filter { !missing.contains($0) }
    }

    func checkCatalog(_ name: String?) throws {
        guard let name, name != catalogName else { return }
        throw ArgumentProblem("These ids are for the catalog “\(name)”, but Atelier has “\(catalogName)” open. "
                              + "Nothing was changed; search again in this catalog.")
    }

    private func unique(_ ids: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        return ids.filter { seen.insert($0).inserted }
    }

    func modeName(_ mode: ViewMode) -> String {
        switch mode {
        case .grid: return "grid"
        case .loupe: return "loupe"
        case .develop: return "develop"
        case .hdr: return "hdr"
        }
    }

    static func count(_ photos: Int) -> String { photos == 1 ? "1 photo" : "\(photos) photos" }

    // MARK: Notice

    /// Shows the notice for a few seconds (longer when it offers Undo).
    func announce(_ text: String, change: String?) {
        let notice = AgentNotice(text: text, changeID: change)
        self.notice = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(change == nil ? 5 : 10))
            if self?.notice == notice { self?.notice = nil }
        }
    }
}

extension ColorLabel {
    init?(_ setting: LabelSetting) {
        switch setting {
        case .red: self = .red
        case .yellow: self = .yellow
        case .green: self = .green
        case .blue: self = .blue
        case .purple: self = .purple
        case .none: return nil
        }
    }
}

/// "Claude wants to rate 120 photos": asked in Atelier's window when one change would touch more
/// photos than Settings > Agents allows without asking.
@MainActor
enum AgentConfirm {
    static func ask(client: String, title: String, count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Let “\(client)” change \(AgentServer.count(count))?"
        alert.informativeText = "\(client) wants to: \(title).\n\nIt can be undone afterwards from the notice in the window. "
            + "Atelier asks when one change touches more than \(AgentSettings.confirmAbove) photos; change that in "
            + "Atelier > Settings… > Agents."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.requestUserAttention(.criticalRequest)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
