import AgentActions
import AgentMCP
import AtelierActions
import AtelierCore
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// The Look profile's tools that read the catalog (AT-050b). They never write, never see a
/// private photo (private imports and collections are hidden from agents whatever View > Show
/// Private Photos says), and run off the main thread. `get_context` and parts of `list_items`
/// read the window and live in `AgentServer`.
struct AgentLookTools: Sendable {
    let catalog: Catalog
    let previews: PreviewCache

    /// What Settings > Agents allows right now.
    struct Options: Sendable {
        var previews: Bool
        var location: Bool
    }

    static func tools(options: Options) -> [MCPTool] {
        var tools = [getContext, searchPhotos, getPhoto, listItems, cullGroups, getDevelop]
        if options.previews {
            tools.insert(getPreview, at: 3)
            // Only the photo carousel calls it; clients without views never see it.
            tools.append(AtelierPhotoCarousel.getThumbnails)
        }
        return tools
    }

    // MARK: Definitions

    static let getContext = MCPTool(
        name: "get_context", title: "What's on screen",
        description: "What Atelier shows now: the mode (grid, loupe, develop, hdr), the photo in front and its file name, "
            + "the selected photo ids (the first few with file names), the sidebar source, the filter, and whether photo "
            + "previews are on (get_preview). Start here when the person says \"this photo\" or \"these\".",
        readOnly: true, idempotent: true)

    static let searchPhotos = MCPTool(
        name: "search_photos", title: "Search photos",
        description: "Finds photos in the catalog, like the Library filter bar. Returns ids and the basics (file name, capture time, "
            + "rating, flag, label, edited, has_notes). All conditions must match. Use get_photo for one photo's full details.",
        inputSchema: objectSchema([
            "text": property("string", "Words in the file name, title, caption, keywords or notes."),
            "collection_id": property("integer", "Only this collection (ids from list_items kind collections)."),
            "import_id": property("integer", "Only this import entry (ids from list_items kind imports)."),
            "folder_id": property("integer", "Only this folder (ids from list_items kind folders)."),
            "min_rating": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(5),
                                   "description": .string("At least this many stars.")]),
            "flag": enumProperty(["picked", "rejected", "unflagged"], "Only photos with this flag."),
            "label": enumProperty(ColorLabel.allCases.map { $0.rawValue.lowercased() }, "Only photos with this color label."),
            "edited": property("boolean", "true: only photos with Develop edits; false: only unedited ones."),
            "has_notes": property("boolean", "true: only photos with notes; false: only photos without."),
            "sort": enumProperty(LibrarySort.allCases.map(\.agentName), "Order of the results (default capture_time)."),
            "descending": property("boolean", "Newest, highest or last first."),
            "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(500),
                              "description": .string("How many to return (default 50).")]),
            "offset": .object(["type": .string("integer"), "minimum": .int(0),
                               "description": .string("Skip this many first, to page through results.")]),
        ]),
        readOnly: true, idempotent: true, ui: AtelierPhotoCarousel.link)

    static let getPhoto = MCPTool(
        name: "get_photo", title: "Photo details",
        description: "One photo's details: file and folder, camera and lens, size, capture time, rating, flag, label, title, "
            + "caption, keywords, notes, whether it has edits, and its cull group. Location only when Atelier allows it.",
        inputSchema: objectSchema(["id": property("integer", "The photo id (from search_photos or get_context).")], required: ["id"]),
        readOnly: true, idempotent: true)

    static let getPreview = MCPTool(
        name: "get_preview", title: "Look at a photo",
        description: "The photo as Atelier shows it (with its edits), as a JPEG up to 1024 pixels. You see it, and chat apps "
            + "that show images (like Docent) show it to the person in the chat, so use it when they ask to see a photo.",
        inputSchema: objectSchema([
            "id": property("integer", "The photo id."),
            "max_size": .object(["type": .string("integer"), "minimum": .int(256), "maximum": .int(1024),
                                 "description": .string("Longest side in pixels (default 1024).")]),
        ], required: ["id"]),
        readOnly: true, idempotent: true)

    static let listItems = MCPTool(
        name: "list_items", title: "List library items",
        description: "Lists collections, import entries, folders, drives, presets (Develop, "
            + "Tone Curve and Color Grading, each with its kind), Edit In apps or AI recipes, with the ids other tools take.",
        inputSchema: objectSchema([
            "kind": enumProperty(["collections", "imports", "folders", "volumes", "presets", "editors", "ai_recipes"],
                                 "What to list."),
        ], required: ["kind"]),
        readOnly: true, idempotent: true)

    static let cullGroups = MCPTool(
        name: "cull_groups", title: "Cull group",
        description: "The photos culled together with a photo (a burst or similar shots, from Library > Cull Import), "
            + "in capture order, with their rating and flag, and for photos the cull didn't keep, Cull's note "
            + "saying why (eyes closed, softer than the keeper, exposure).",
        inputSchema: objectSchema(["id": property("integer", "Any photo in the group.")], required: ["id"]),
        readOnly: true, idempotent: true, ui: AtelierPhotoCarousel.link)

    static let getDevelop = MCPTool(
        name: "get_develop", title: "Develop settings",
        description: "A photo's Develop settings as Atelier stores them (white balance, tone, curves, color, detail, lens, "
            + "crop, effects and masks). Values at their defaults mean no change.",
        inputSchema: objectSchema(["id": property("integer", "The photo id.")], required: ["id"]),
        readOnly: true, idempotent: true)

    // MARK: Calls

    func call(_ name: String, _ arguments: [String: JSONValue], options: Options) -> MCPToolResult {
        do {
            switch name {
            case Self.searchPhotos.name: return try searchPhotos(arguments)
            case Self.getPhoto.name: return try getPhoto(arguments, options: options)
            case Self.getPreview.name:
                guard options.previews else { return .error(Self.previewsOff) }
                return try getPreview(arguments)
            case AtelierPhotoCarousel.getThumbnails.name:
                guard options.previews else { return .error(Self.previewsOff) }
                return try getThumbnails(arguments)
            case Self.cullGroups.name: return try cullGroup(arguments)
            case Self.getDevelop.name: return try getDevelop(arguments)
            case Self.listItems.name: return try listCatalogItems(arguments)
            default: return .error("Unknown tool: \(name).")
            }
        } catch let problem as ArgumentProblem {
            return .error(problem.message)
        } catch {
            return .error("Atelier couldn't read the catalog: \(error.localizedDescription)")
        }
    }

    /// get_preview's caption, the result's text next to the image.
    static func previewCaption(id: Int64, filename: String?, maxSize: Int) -> JSONValue {
        var members: [String: JSONValue] = ["id": .int(Int(id)), "max_size": .int(maxSize)]
        if let filename { members["filename"] = .string(filename) }
        return .object(members)
    }

    static let previewsOff = "Atelier doesn't let agents see photos. The person can turn on \"Let agents see photo previews\" "
        + "in Atelier > Settings… > Agents."

    private func searchPhotos(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        var filter = LibraryFilter(groupsRawPairs: FilePairs.isGrouping, privacy: .hidden)
        let lists = try publicLists()
        if let id = try optionalID(arguments, "collection_id") {
            guard lists.collections.contains(id) else { throw ArgumentProblem("No collection with id \(id). See list_items kind collections.") }
            filter.scope = .collection(id)
        } else if let id = try optionalID(arguments, "import_id") {
            guard lists.imports.contains(id) else { throw ArgumentProblem("No import entry with id \(id). See list_items kind imports.") }
            filter.scope = .importGroup(id)
        } else if let id = try optionalID(arguments, "folder_id") {
            guard lists.folders.contains(id) else { throw ArgumentProblem("No folder with id \(id). See list_items kind folders.") }
            filter.scope = .folder(id)
        }
        filter.text = arguments["text"]?.stringValue ?? ""
        if let rating = arguments["min_rating"] {
            guard let stars = rating.intValue, (0...5).contains(stars) else { throw ArgumentProblem("min_rating is 0 to 5.") }
            filter.minRating = stars
        }
        if let flag = arguments["flag"] {
            switch flag.stringValue {
            case "picked": filter.flag = Flag.picked
            case "rejected": filter.flag = Flag.rejected
            case "unflagged": filter.flag = Flag.none
            default: throw ArgumentProblem("flag is picked, rejected or unflagged.")
            }
        }
        if let label = arguments["label"] {
            guard let match = ColorLabel.allCases.first(where: { $0.rawValue.lowercased() == label.stringValue?.lowercased() }) else {
                throw ArgumentProblem("label is one of " + ColorLabel.allCases.map { $0.rawValue.lowercased() }.joined(separator: ", ") + ".")
            }
            filter.colorLabel = match
        }
        if let edited = arguments["edited"] {
            guard let value = edited.boolValue else { throw ArgumentProblem("edited is true or false.") }
            filter.edited = value
        }
        if let notes = arguments["has_notes"] {
            guard let value = notes.boolValue else { throw ArgumentProblem("has_notes is true or false.") }
            filter.notes = value ? .hasNotes : .noNotes
        }
        if let sort = arguments["sort"] {
            guard let match = LibrarySort.allCases.first(where: { $0.agentName == sort.stringValue }) else {
                let names = LibrarySort.allCases.map(\.agentName)
                let hint = sort.stringValue.flatMap { Suggest.closest(to: $0, in: names) }.map { " Did you mean \($0)?" } ?? ""
                throw ArgumentProblem("sort is one of \(names.joined(separator: ", ")).\(hint)")
            }
            filter.sort = match
        }
        filter.ascending = !(arguments["descending"]?.boolValue ?? false)
        let limit = min(max(arguments["limit"]?.intValue ?? 50, 1), 500)
        let offset = max(arguments["offset"]?.intValue ?? 0, 0)

        let rows = try catalog.assetRows(filter: filter)
        let page = rows.dropFirst(offset).prefix(limit)
        var result: [String: JSONValue] = [
            "total": .int(rows.count),
            "offset": .int(offset),
            "photos": .array(page.map(Self.json(row:))),
        ]
        if offset + page.count < rows.count { result["next_offset"] = .int(offset + page.count) }
        return .json(.object(result))
    }

    private func getPhoto(_ arguments: [String: JSONValue], options: Options) throws -> MCPToolResult {
        let id = try publicPhoto(arguments)
        guard let detail = try catalog.detail(for: id) else { throw ArgumentProblem(Self.noPhoto(id)) }
        let asset = detail.asset, metadata = detail.metadata
        var photo: [String: JSONValue] = [
            "id": .int(Int(id)),
            "filename": .string(asset.filename),
            "folder": .string(detail.folder.displayName),
            "folder_id": Self.id(detail.folder.id),
            "volume": .string(detail.volume.name),
            "online": .bool(detail.volume.isOnline && detail.fileURL != nil),
            "file_size": .int(Int(asset.fileSize)),
            "is_raw": .bool(asset.isRaw),
            "imported_at": .string(Self.date(asset.importedAt)),
            "rating": .int(metadata.rating),
            "flag": .string(metadata.flag.agentName),
            "label": Self.text(metadata.colorLabel?.rawValue.lowercased()),
            "keywords": .array(detail.keywords.map { .string($0) }),
        ]
        if let path = detail.fileURL?.path { photo["path"] = .string(path) }
        if let time = asset.captureTime { photo["capture_time"] = .string(Self.date(time)) }
        let camera = [asset.cameraMake, asset.cameraModel].compactMap { $0 }.joined(separator: " ")
        if !camera.isEmpty { photo["camera"] = .string(camera) }
        if let lens = asset.lens { photo["lens"] = .string(lens) }
        if let width = asset.width, let height = asset.height { photo["width"] = .int(width); photo["height"] = .int(height) }
        if let title = metadata.title, !title.isEmpty { photo["title"] = .string(title) }
        if let caption = metadata.caption, !caption.isEmpty { photo["caption"] = .string(caption) }
        if let original = asset.virtualCopyOf { photo["virtual_copy_of"] = .int(Int(original)) }
        if let latitude = metadata.latitude, let longitude = metadata.longitude {
            if options.location {
                photo["location"] = .object(["latitude": .number(latitude), "longitude": .number(longitude)])
            } else {
                photo["location"] = .string("hidden (Atelier > Settings… > Agents > Include location)")
            }
        }
        let settings = try catalog.developSettings(for: id)
        photo["has_edits"] = .bool(!settings.isNeutral)
        let group = try publicMembers(of: catalog.cullGroup(of: id))
        if !group.isEmpty { photo["cull_group_size"] = .int(group.count) }
        // Newest first, as the notes panel shows them (AT-058).
        let notes = try catalog.notes(for: id).filter { !NoteText.cleaned($0.text).isEmpty }
        if !notes.isEmpty {
            photo["notes"] = .array(notes.map { note in
                var entry: [String: JSONValue] = [
                    "text": .string(note.text), "author": .string(note.author),
                    "created": .string(Self.date(note.createdAt)),
                ]
                if let edited = note.editedAt { entry["edited"] = .string(Self.date(edited)) }
                return .object(entry)
            })
        }
        return .json(.object(photo))
    }

    private func getPreview(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let id = try publicPhoto(arguments)
        let size = min(max(arguments["max_size"]?.intValue ?? 1024, 256), 1024)
        let candidates: [PreviewCache.Size] = size <= 256 ? [.thumbnail, .preview] : [.preview, .thumbnail]
        guard let url = candidates.map({ previews.url(for: id, size: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ArgumentProblem("Photo \(id) has no preview yet. It appears once Atelier has shown the photo in the grid.")
        }
        guard let data = Self.jpeg(from: url, maxPixels: size) else {
            throw ArgumentProblem("Atelier couldn't read the preview of photo \(id).")
        }
        // The file name lets the model name what it shows, instead of guessing from an earlier list.
        let filename = try catalog.detail(for: id)?.asset.filename
        return .image(data, mimeType: "image/jpeg", caption: Self.previewCaption(id: id, filename: filename, maxSize: size))
    }

    /// Thumbnails for the photo carousel, as data URLs. A private or unknown photo is left out,
    /// like one without a preview yet.
    private func getThumbnails(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let ids: [Int64]
        switch AtelierPhotoCarousel.thumbnailIDs(arguments) {
        case .failure(let problems): throw ArgumentProblem(problems.text)
        case .success(let value): ids = value
        }
        let hidden = try catalog.privatePhotoIDs(among: ids)
        var thumbnails: [JSONValue] = []
        var missing: [JSONValue] = []
        for id in ids {
            guard !hidden.contains(id), try catalog.detail(for: id) != nil,
                  let url = [PreviewCache.Size.thumbnail, .preview].map({ previews.url(for: id, size: $0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let data = Self.jpeg(from: url, maxPixels: AtelierPhotoCarousel.thumbnailSize) else {
                missing.append(.int(Int(id)))
                continue
            }
            thumbnails.append(.object(["id": .int(Int(id)),
                                       "data": .string("data:image/jpeg;base64," + data.base64EncodedString())]))
        }
        let text = "\(thumbnails.count) thumbnails" + (missing.isEmpty ? "." : ", \(missing.count) without a preview yet.")
        return .json(.object(["thumbnails": .array(thumbnails), "missing": .array(missing)]), text: text)
    }

    private func cullGroup(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let id = try publicPhoto(arguments)
        let members = try publicMembers(of: catalog.cullGroup(of: id))
        guard !members.isEmpty else {
            return .json(.object(["id": .int(Int(id)), "photos": .array([]),
                                  "note": .string("This photo was never culled with others.")]))
        }
        let summaries: [JSONValue] = try members.compactMap { member in
            guard let detail = try catalog.detail(for: member) else { return nil }
            var summary: [String: JSONValue] = [
                "id": .int(Int(member)),
                "filename": .string(detail.asset.filename),
                "capture_time": Self.text(detail.asset.captureTime.map(Self.date)),
                "rating": .int(detail.metadata.rating),
                "flag": .string(detail.metadata.flag.agentName),
            ]
            // The newest note by Cull: its reasons for not keeping the photo (AT-058).
            if let reason = try catalog.notes(for: member).first(where: { $0.source == .cull }) {
                summary["cull_note"] = .string(reason.text)
            }
            return .object(summary)
        }
        return .json(.object(["id": .int(Int(id)), "photos": .array(summaries)]))
    }

    private func getDevelop(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let id = try publicPhoto(arguments)
        let settings = try catalog.developSettings(for: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var value = JSONValue(parsing: try encoder.encode(settings)), case .object(var members) = value else {
            throw ArgumentProblem("Atelier couldn't read the Develop settings of photo \(id).")
        }
        // Brush strokes can be large: past a limit, masks are summarized instead.
        if value.compactText.utf8.count > 256 * 1024, let masks = members["masks"]?.arrayValue {
            members["masks"] = .string("\(masks.count) masks (too large to list)")
        }
        members["edited"] = .bool(!settings.isNeutral)
        value = .object(members)
        return .json(value)
    }

    /// The catalog's lists (`kind` presets and editors come from `AgentServer`).
    private func listCatalogItems(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let kind = arguments["kind"]?.stringValue ?? ""
        let grouping = FilePairs.isGrouping
        let items: [JSONValue] = try catalog.writer.read { db -> [JSONValue] in
            switch kind {
            case "collections":
                return try Catalog.fetchCollections(db, privacy: .hidden).map { collection -> JSONValue in
                    .object(["id": Self.id(collection.id), "name": .string(collection.name),
                             "is_set": .bool(collection.isSet),
                             "parent_id": Self.id(collection.parentId)])
                }
            case "imports":
                return try Catalog.fetchImportGroupSummaries(db, groupingRawPairs: grouping, privacy: .hidden).map { entry -> JSONValue in
                    .object(["id": .int(Int(entry.id)), "name": .string(entry.name),
                             "created_at": .string(Self.date(entry.createdAt)), "photo_count": .int(entry.photoCount)])
                }
            case "folders":
                return try Catalog.fetchFolders(db, privacy: .hidden).map { folder -> JSONValue in
                    .object(["id": Self.id(folder.id), "path": .string(folder.displayName),
                             "volume_id": .int(Int(folder.volumeId))])
                }
            case "volumes":
                return try Volume.order(Column("name")).fetchAll(db).map { volume -> JSONValue in
                    .object(["id": Self.id(volume.id), "name": .string(volume.name),
                             "kind": .string(volume.kind.rawValue), "online": .bool(volume.isOnline)])
                }
            case "ai_recipes":
                return AIRecipe.allCases.map { recipe -> JSONValue in .object(["id": .string(recipe.rawValue), "title": .string(recipe.title)]) }
            default:
                let kinds = ["collections", "imports", "folders", "volumes", "presets", "editors", "ai_recipes"]
                let hint = Suggest.closest(to: kind, in: kinds).map { " Did you mean \($0)?" } ?? ""
                throw ArgumentProblem("kind is one of \(kinds.joined(separator: ", ")).\(hint)")
            }
        }
        return .json(.object(["kind": .string(kind), "items": .array(items)]))
    }

    // MARK: Privacy

    /// The ids of the lists agents may name: not private.
    private func publicLists() throws -> (collections: Set<Int64>, imports: Set<Int64>, folders: Set<Int64>) {
        try catalog.writer.read { db in
            (Set(try Catalog.fetchCollections(db, privacy: .hidden).compactMap(\.id)),
             Set(try Catalog.fetchImportGroupSummaries(db, privacy: .hidden).map(\.id)),
             Set(try Catalog.fetchFolders(db, privacy: .hidden).compactMap(\.id)))
        }
    }

    /// The `id` argument, when it names a photo agents may see. A private photo reads as missing.
    private func publicPhoto(_ arguments: [String: JSONValue]) throws -> Int64 {
        guard let id = try optionalID(arguments, "id") else { throw ArgumentProblem("id is required: a photo id from search_photos.") }
        guard try catalog.privatePhotoIDs(among: [id]).isEmpty, try catalog.detail(for: id) != nil else {
            throw ArgumentProblem(Self.noPhoto(id))
        }
        return id
    }

    private func publicMembers(of ids: [Int64]) throws -> [Int64] {
        let hidden = try catalog.privatePhotoIDs(among: ids)
        return ids.filter { !hidden.contains($0) }
    }

    private func optionalID(_ arguments: [String: JSONValue], _ key: String) throws -> Int64? {
        guard let value = arguments[key] else { return nil }
        guard let id = value.intValue else { throw ArgumentProblem("\(key) is a whole number.") }
        return Int64(id)
    }

    static func noPhoto(_ id: Int64) -> String { "No photo with id \(id). Use search_photos to find ids." }

    // MARK: JSON

    static func json(row: AssetRow) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .int(Int(row.id)),
            "filename": .string(row.filename),
            "rating": .int(row.rating),
            "flag": .string(row.flag.agentName),
            "edited": .bool(row.hasEdits),
        ]
        if let time = row.captureTime { members["capture_time"] = .string(date(time)) }
        if let label = row.colorLabel { members["label"] = .string(label.rawValue.lowercased()) }
        if row.isCropped { members["cropped"] = .bool(true) }
        if row.hasMasks { members["masks"] = .bool(true) }
        if row.isOffline { members["offline"] = .bool(true) }
        if row.hasNotes { members["has_notes"] = .bool(true) }
        if let parent = row.stackParentId { members["stacked_on"] = .int(Int(parent)) }
        if let kind = row.stackKind { members["version_kind"] = .string(kind.rawValue) }
        if let name = row.stackName { members["version_name"] = .string(name) }
        if let count = row.stackCount, count > 0 { members["stack_count"] = .int(count) }
        if let size = row.cullGroupSize { members["cull_group_size"] = .int(size) }
        if let formats = row.pairedFormats { members["paired_formats"] = .string(formats) }
        return .object(members)
    }

    static func id(_ value: Int64?) -> JSONValue { value.map { JSONValue.int(Int($0)) } ?? .null }

    static func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

    static func date(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func jpeg(from url: URL, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func objectSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    static func enumProperty(_ values: [String], _ description: String) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map { .string($0) }), "description": .string(description)])
    }
}

/// A bad argument, told to the model so it can try again.
struct ArgumentProblem: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension Flag {
    var agentName: String {
        switch self {
        case .picked: return "picked"
        case .rejected: return "rejected"
        case .none: return "unflagged"
        }
    }
}

extension LibrarySort {
    /// snake_case for agents: capture_time, import_order, file_name, rating, edit_time.
    var agentName: String {
        rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name += "_" + character.lowercased() } else { name.append(character) }
        }
    }
}
