import AgentActions
import Foundation
import XCTest

// A tiny Easel-shaped host: documents and layers, nothing about photos. It proves the shared
// module works for an app other than Atelier.

private final class SketchHost {
    var layers: [String: String] = ["l1": "Sky", "l2": "Hills", "l3": "Sun"]
    var selectedLayers: [String] = ["l2"]
    var zoom = 1.0
    var gridShown = false
    var exported: [String] = []
}

private struct RenameParameters: ActionParameters, Hashable {
    var name: String
    static let example = RenameParameters(name: "Layer")
    static let fieldNotes = ["name": FieldNote("The new name.")]
}

private enum BlendChoice: String, AgentEnum { case normal, multiply, screen }

private struct StyleParameters: ActionParameters {
    var blend: BlendChoice
    var opacity: Double
    var steps: Int64
    var tags: [String]
    var note: String?
    static let example = StyleParameters(blend: .normal, opacity: 0.5, steps: 2, tags: ["a"], note: "n")
    static let fieldNotes = ["opacity": FieldNote("0 to 1.", minimum: 0, maximum: 1)]
}

private extension TargetKind {
    static let layers = TargetKind("layers")
    static let documents = TargetKind("documents")
}

private enum SketchAction {
    static let renameLayer = Action<RenameParameters>(
        "layer.rename", "Rename Layer…", place: "Layer > Rename", summary: "Renames the layers.",
        kind: .edit, targets: .layers)
    static let deleteLayer = Action<NoParameters>(
        "layer.delete", "Delete Layer", place: "Layer > Delete", summary: "Deletes the layers.",
        kind: .deletes, targets: .layers)
    static let exportDocument = Action<NoParameters>(
        "file.export", "Export…", place: "File > Export…", summary: "Exports the document.",
        kind: .writesFiles, targets: .documents, shortcut: KeyShortcut("e", [.command, .shift]))
    static let zoomIn = Action<NoParameters>(
        "view.zoomIn", "Zoom In", place: "View > Zoom In", summary: "Zooms in.", kind: .view,
        shortcut: KeyShortcut("="))
    static let showGrid = Action<NoParameters>(
        "view.showGrid", "Show Grid", place: "View > Show Grid", summary: "Shows the grid.", kind: .view,
        hidden: "A drawing aid for people.")
    static let style = Action<StyleParameters>(
        "layer.style", "Layer Style…", place: "Layer > Style", summary: "Sets the style.", kind: .edit,
        targets: .layers)

    static let catalog = ActionCatalog(app: "Sketch", actions: [
        renameLayer.descriptor, deleteLayer.descriptor, exportDocument.descriptor, zoomIn.descriptor,
        showGrid.descriptor, style.descriptor,
    ])
}

final class AgentActionsTests: XCTestCase {
    func testKindsSetTiers() {
        XCTAssertEqual(ActionKind.reads.tier, .runs)
        XCTAssertEqual(ActionKind.view.tier, .runs)
        XCTAssertEqual(ActionKind.edit.tier, .undoable)
        XCTAssertEqual(ActionKind.writesFiles.tier, .asksFirst)
        XCTAssertEqual(ActionKind.opensApp.tier, .asksFirst)
        XCTAssertEqual(ActionKind.deletes.tier, .never)
        XCTAssertFalse(SketchAction.deleteLayer.descriptor.isExposed, "Deletes are never exposed")
        XCTAssertFalse(SketchAction.showGrid.descriptor.isExposed)
        XCTAssertTrue(SketchAction.exportDocument.descriptor.isExposed, "Exposed by default")
    }

    func testSchemaIsReadFromTheSwiftType() {
        let schema = SketchAction.style.descriptor.parameters
        XCTAssertEqual(schema.problems, [])
        XCTAssertEqual(schema.fields.map(\.name), ["blend", "opacity", "steps", "tags", "note"])
        XCTAssertEqual(schema.fields.map(\.type), [.choice(["normal", "multiply", "screen"]), .number, .integer,
                                                   .list(.string), .string])
        XCTAssertEqual(schema.fields.map(\.required), [true, true, true, true, false])
        XCTAssertEqual(schema.fields[1].note?.maximum, 1)
        XCTAssertEqual(ParameterSchema.of(NoParameters.self).fields, [])
        XCTAssertEqual(ParameterSchema.of(UUIDParameters.self).fields.map(\.type), [.string])
    }

    func testSchemaProblemsAreReported() {
        XCTAssertFalse(ParameterSchema.of(EmptyListParameters.self).problems.isEmpty)
        XCTAssertFalse(ParameterSchema.of(StrayNoteParameters.self).problems.isEmpty)
        XCTAssertFalse(ParameterSchema.of(NestedParameters.self).problems.isEmpty)
    }

    func testSchemaJSON() {
        let json = SketchAction.renameLayer.descriptor.parameters.json.text
        XCTAssertEqual(json, """
        {
          "additionalProperties": false,
          "properties": {
            "name": {
              "description": "The new name.",
              "type": "string"
            }
          },
          "required": [
            "name"
          ],
          "type": "object"
        }

        """)
    }

    func testCatalogProblems() {
        XCTAssertEqual(SketchAction.catalog.problems, [])
        let bad = ActionCatalog(app: "Bad", actions: [
            SketchAction.zoomIn.descriptor, SketchAction.zoomIn.descriptor,
            Action<NoParameters>("Zoom", "Zoom", place: "View", summary: "Zooms.", kind: .view).descriptor,
            Action<NoParameters>("view.blank", " ", place: "View", summary: "Zooms.", kind: .view, hidden: " ").descriptor,
        ])
        let problems = bad.problems
        XCTAssertTrue(problems.contains("view.zoomIn: two actions share this id"), "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("Zoom: ids are") }, "\(problems)")
        XCTAssertTrue(problems.contains("view.blank: no title"), "\(problems)")
        XCTAssertTrue(problems.contains("view.blank: hidden from agents without a reason"), "\(problems)")
    }

    func testIDs() {
        XCTAssertTrue(ActionID("photo.setRating").isWellFormed)
        XCTAssertTrue(ActionID("a.b.c2").isWellFormed)
        XCTAssertFalse(ActionID("photo").isWellFormed)
        XCTAssertFalse(ActionID("Photo.set").isWellFormed)
        XCTAssertFalse(ActionID("photo..set").isWellFormed)
        XCTAssertFalse(ActionID("photo.set-rating").isWellFormed)
    }

    func testShortcutDisplay() {
        XCTAssertEqual(KeyShortcut("i", [.command, .shift]).display, "⇧⌘I")
        XCTAssertEqual(KeyShortcut("1", [.command, .option]).display, "⌥⌘1")
        XCTAssertEqual(KeyShortcut("h", [.control]).display, "⌃H")
        XCTAssertEqual(KeyShortcut("F6", []).display, "F6")
    }

    // XCTest runs tests on the main thread; @MainActor test methods crash Linux test discovery.
    func testRegistryRunsWithResolvedTargets() throws {
        try MainActor.assumeIsolated { try registryRuns() }
    }

    @MainActor
    private func registryRuns() throws {
        let host = SketchHost()
        let registry = ActionRegistry<SketchHost, String>(catalog: SketchAction.catalog, context: host) { host, kind in
            kind == .layers ? host.selectedLayers : ["doc"]
        }
        registry.bind(SketchAction.renameLayer) { host, parameters, ids in
            for id in ids { host.layers[id] = parameters.name }
        }
        registry.bind(SketchAction.exportDocument, enabled: { !$0.layers.isEmpty }) { host, _, ids in
            host.exported += ids
        }
        registry.bindChecked(SketchAction.zoomIn, shortcutWhen: { $0.zoom < 8 }) { host, _, _ in
            guard host.zoom < 8 else { return false }
            host.zoom *= 2
            return true
        }
        registry.bind(SketchAction.showGrid, isOn: { $0.gridShown }) { host, _, _ in host.gridShown.toggle() }

        // From the selection.
        XCTAssertTrue(registry.run(SketchAction.renameLayer, RenameParameters(name: "Ridge")))
        XCTAssertEqual(host.layers["l2"], "Ridge")
        // Named explicitly, as the right-click menu and agents do.
        registry.run(SketchAction.renameLayer, RenameParameters(name: "Top"), targets: ["l1", "l3"])
        XCTAssertEqual(host.layers, ["l1": "Top", "l2": "Ridge", "l3": "Top"])
        // From JSON, as an agent sends it.
        XCTAssertTrue(try registry.run("layer.rename", json: Data(#"{"name":"Glow"}"#.utf8), targets: ["l3"]))
        XCTAssertEqual(host.layers["l3"], "Glow")
        XCTAssertThrowsError(try registry.run("layer.rename", json: Data(#"{"title":"x"}"#.utf8)))
        XCTAssertFalse(try registry.run("layer.unknown", json: Data()))

        registry.run(SketchAction.exportDocument)
        XCTAssertEqual(host.exported, ["doc"])
        XCTAssertTrue(registry.isEnabled(SketchAction.exportDocument.id))
        XCTAssertFalse(registry.isEnabled(SketchAction.deleteLayer.id), "Unbound actions are disabled")

        XCTAssertEqual(registry.activeShortcut(SketchAction.zoomIn.id), KeyShortcut("="))
        for _ in 0..<3 { XCTAssertTrue(registry.run(SketchAction.zoomIn)) }
        XCTAssertFalse(registry.run(SketchAction.zoomIn), "A checked handler can decline")
        XCTAssertNil(registry.activeShortcut(SketchAction.zoomIn.id))
        XCTAssertEqual(registry.activeShortcut(SketchAction.exportDocument.id), KeyShortcut("e", [.command, .shift]))

        XCTAssertFalse(registry.isOn(SketchAction.showGrid.id))
        registry.run(SketchAction.showGrid)
        XCTAssertTrue(registry.isOn(SketchAction.showGrid.id))

        XCTAssertEqual(registry.unbound, [SketchAction.deleteLayer.id, SketchAction.style.id])
        XCTAssertEqual(registry.problems, [])
    }

    func testRegistryReportsBindingMistakes() {
        MainActor.assumeIsolated { registryMistakes() }
    }

    @MainActor
    private func registryMistakes() {
        let host = SketchHost()
        let registry = ActionRegistry<SketchHost, String>(catalog: SketchAction.catalog, context: host) { _, _ in [] }
        let stray = Action<NoParameters>("layer.stray", "Stray", place: "Nowhere", summary: "Not listed.", kind: .view)
        registry.bind(stray) { _, _, _ in }
        registry.bind(SketchAction.zoomIn) { _, _, _ in }
        registry.bind(SketchAction.zoomIn) { _, _, _ in }
        XCTAssertEqual(registry.problems, ["layer.stray: bound but not in the Sketch catalog", "view.zoomIn: bound twice"])
    }

    func testJSONWriter() {
        let value = JSONValue.object([
            "b": .array([.int(1), .number(1.5), .number(2), .bool(true), .null]),
            "a": .string("quote \" slash \\ line\n tab\t bell\u{07} é"),
            "c": .object([:]),
            "d": .array([]),
        ])
        XCTAssertEqual(value.text, """
        {
          "a": "quote \\" slash \\\\ line\\n tab\\t bell\\u0007 é",
          "b": [
            1,
            1.5,
            2,
            true,
            null
          ],
          "c": {},
          "d": []
        }

        """)
    }
}

private struct UUIDParameters: ActionParameters {
    var id: UUID
    static let example = UUIDParameters(id: UUID())
}

private struct EmptyListParameters: ActionParameters {
    var ids: [Int]
    static let example = EmptyListParameters(ids: [])
}

private struct StrayNoteParameters: ActionParameters {
    var stars: Int
    static let example = StrayNoteParameters(stars: 1)
    static let fieldNotes = ["star": FieldNote("Misspelled.")]
}

private struct NestedParameters: ActionParameters {
    struct Inner: Codable { var x: Int }
    var inner: Inner
    static let example = NestedParameters(inner: Inner(x: 1))
}
