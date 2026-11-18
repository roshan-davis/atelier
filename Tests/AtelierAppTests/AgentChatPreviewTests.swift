import AgentActions
import AgentMCP
import AtelierActions
import AtelierCore
import Foundation
import XCTest
@testable import AtelierApp

/// "Show me this photo" in a chat app: get_preview shows the photo to the person, show only
/// changes Atelier's window, and get_context and get_preview name the photo by its file name.
final class AgentChatPreviewTests: XCTestCase {
    let client = AgentClient(id: "test.client#T", name: "Test", pid: 1)

    func testDescriptionsSayWhichToolShowsThePhotoInTheChat() {
        XCTAssertTrue(AgentLookTools.getPreview.description.contains("show it to the person in the chat"))
        XCTAssertTrue(AgentLookTools.getContext.description.contains("file name"))
    }

    /// Instructions are read once at initialize, so they don't follow the previews switch;
    /// get_context does.
    func testInstructionsPointAtGetPreviewWhateverTheSwitch() {
        XCTAssertTrue(AtelierMCPHost.instructions.hasSuffix("When the person asks to see a photo in the chat, "
            + "call get_preview if it's offered; show only changes Atelier's window."), AtelierMCPHost.instructions)
    }

    func testPreviewCaptionNamesTheFile() {
        XCTAssertEqual(AgentLookTools.previewCaption(id: 3864, filename: "RHN_2683.NEF", maxSize: 1024),
                       .object(["id": .int(3864), "filename": .string("RHN_2683.NEF"), "max_size": .int(1024)]))
        XCTAssertEqual(AgentLookTools.previewCaption(id: 1, filename: nil, maxSize: 512),
                       .object(["id": .int(1), "max_size": .int(512)]))
    }

    @MainActor
    func testContextSaysWhenPreviewsAreOff() async throws {
        let saved = UserDefaults.standard.object(forKey: AgentSettings.previewsKey)
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: AgentSettings.previewsKey) }
        let (library, _) = try await makeLibrary(["landscape"])
        for previews in [false, true] {
            UserDefaults.standard.set(previews, forKey: AgentSettings.previewsKey)
            let result = try XCTUnwrap(library.agents.callOnMain("get_context", [:], client: client, profile: .look))
            let context = try XCTUnwrap(result.structured)
            XCTAssertEqual(context["previews"], .bool(previews))
            XCTAssertEqual(context["previews_note"], previews ? nil
                : .string("Photo previews are off in Atelier > Settings > Agents, so photos can't be shown in the chat."))
        }
    }

    @MainActor
    func testContextNamesThePhotoInFrontAndTheFirstSelected() async throws {
        let (library, ids) = try await makeLibrary(["landscape", "portrait"])
        library.selection = Set(ids)
        library.focusedID = ids[1]
        let result = try XCTUnwrap(library.agents.callOnMain("get_context", [:], client: client, profile: .look))
        XCTAssertFalse(result.isError, result.text)
        let context = try XCTUnwrap(result.structured)
        XCTAssertEqual(context["photo_in_front"], .int(Int(ids[1])))
        XCTAssertEqual(context["photo_in_front_filename"], .string("portrait.jpg"))
        XCTAssertEqual(context["previews"], .bool(AgentSettings.options.previews))
        XCTAssertEqual(context["previews_note"] == nil, AgentSettings.options.previews)
        XCTAssertEqual(context["selected_photos"], .array(ids.sorted().map { id in
            .object(["id": .int(Int(id)), "filename": .string(id == ids[0] ? "landscape.jpg" : "portrait.jpg")])
        }))
    }

    @MainActor
    private func makeLibrary(_ fixtures: [String]) async throws -> (LibraryModel, [Int64]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures")
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("AgentChat.atelier"))
        var ids: [Int64] = []
        for fixture in fixtures {
            let copy = folder.appendingPathComponent(fixture + ".jpg")
            try FileManager.default.copyItem(at: directory.appendingPathComponent(fixture + ".jpg"), to: copy)
            let imported = await Importer(catalog: catalog, previews: nil).run(sources: [copy],
                                                                               options: ImportOptions(buildPreviews: false))
            ids.append(try XCTUnwrap(imported.importedAssetIDs.first))
        }
        return (LibraryModel(catalog: catalog), ids)
    }
}
