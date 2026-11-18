import AgentActions
import AgentMCP
import AtelierActions
import Foundation
import StudioSkills
import XCTest
@testable import AtelierApp

/// Skills in Atelier (SL-002c): the catalog the library checks them against, get_skill,
/// prompts and the instructions paragraph, and what a client's grants say in prepared text.
final class AgentSkillsTests: XCTestCase {
    let cull = Skill(name: "cull-import", title: "Cull a new import", description: "Picks the keepers of each burst.",
                     instructions: "Group with [cull_groups](tool:cull_groups), then [Set Flag](action:photo.setFlag) and "
                         + "[Set Rating](action:photo.setRating) 3 on {{collection}}. See [sharpness](sharpness.md).",
                     files: [.init(name: "sharpness.md", text: "# Judging sharpness\nZoom to 100%.")],
                     arguments: [.init(name: "collection", description: "Which collection.", required: false)])
    let off = Skill(name: "share-shop", title: "Share to the shop", description: "Exports for the shop.", isEnabled: false)

    func testCatalogHasEveryActionAndTheTypedTools() {
        let catalog = AtelierSkills.catalog
        XCTAssertEqual(catalog.appName, "Atelier")
        XCTAssertEqual(catalog.entries.filter { $0.kind == .action }.count, AtelierAction.catalog.actions.count)
        let rating = catalog.action("photo.setRating")
        XCTAssertEqual(rating?.tier, .undoable)
        XCTAssertEqual(rating?.menu, "Photo menu")
        XCTAssertFalse(rating?.parameters.isEmpty ?? true)
        XCTAssertEqual(catalog.tool("search_photos")?.tier, .runs)
        XCTAssertEqual(catalog.tool("show")?.tier, .runs)
        XCTAssertEqual(catalog.tool("set_metadata")?.tier, .undoable)
        XCTAssertNotNil(catalog.tool("adjust"))
        XCTAssertNotNil(catalog.tool("get_preview"), "offered whatever the previews setting, so skills don't flip to warnings")
        // command_run is how actions run, and the carousel's thumbnails are only for its view.
        XCTAssertNil(catalog.tool(CommandRunTool.name))
        XCTAssertNil(catalog.tool(AtelierPhotoCarousel.getThumbnails.name))
        // The editor never offers get_skill itself, nor a delete.
        XCTAssertFalse(catalog.offered.contains { $0.id == "get_skill" })
        XCTAssertFalse(catalog.offered.contains { $0.tier == .never })
        XCTAssertEqual(catalog.menuOrder.first, "File")
    }

    func testToolParametersReadFromTheirSchemas() {
        let metadata = AtelierSkills.catalog.tool("set_metadata")?.parameters ?? []
        let rating = metadata.first { $0.name == "rating" }
        XCTAssertEqual(rating?.type, "integer, 0 to 5")
        XCTAssertEqual(metadata.first { $0.name == "label" }?.choices, ["red", "yellow", "green", "blue", "purple", "none"])
        let skill = AtelierSkills.catalog.tool("get_skill")?.parameters ?? []
        XCTAssertEqual(skill.first?.name, "name", "required first")
        XCTAssertEqual(skill.first?.required, true)
    }

    func testGrantNotesSayWhatThisClientCantRun() throws {
        let catalog = AtelierSkills.catalog
        let rating = try XCTUnwrap(catalog.action("photo.setRating"))
        XCTAssertEqual(AtelierSkills.grantNote(rating, profile: .look, clientName: "Docent"),
                       "Set Rating needs the Organize profile; Docent has Look.")
        XCTAssertNil(AtelierSkills.grantNote(rating, profile: .organize, clientName: "Docent"))
        let export = try XCTUnwrap(catalog.action("file.export"))
        XCTAssertEqual(AtelierSkills.grantNote(export, profile: .everything, clientName: "Docent"),
                       "Agents can't run \(export.title) in this version of Atelier.")
        let adjust = try XCTUnwrap(catalog.tool("adjust"))
        XCTAssertNotNil(AtelierSkills.grantNote(adjust, profile: .organize, clientName: "Docent"))
    }

    func testGetSkillReturnsPreparedTextAndItsFiles() {
        let result = AtelierSkills.getSkill(["name": .string("cull-import")], skills: [cull, off], profile: .look,
                                            clientName: "Docent")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.hasPrefix("# Cull a new import"))
        XCTAssertTrue(result.text.contains("Set Rating (`command_run` id `photo.setRating`, undoable)"), result.text)
        XCTAssertTrue(result.text.contains("`cull_groups`"))
        XCTAssertTrue(result.text.contains("on not given"), "an optional argument left out")
        XCTAssertTrue(result.text.contains("Set Rating needs the Organize profile; Docent has Look."))
        XCTAssertTrue(result.text.contains("- sharpness.md: Judging sharpness"))

        let file = AtelierSkills.getSkill(["name": .string("cull-import"), "file": .string("sharpness.md")],
                                          skills: [cull], profile: .edit, clientName: "Docent")
        XCTAssertEqual(file.text, "# Judging sharpness\nZoom to 100%.")
    }

    func testGetSkillExplainsWhatIsThere() {
        let typo = AtelierSkills.getSkill(["name": .string("cull-imports")], skills: [cull, off], profile: .look, clientName: "Docent")
        XCTAssertTrue(typo.isError)
        XCTAssertEqual(typo.text, "There is no skill named cull-imports. Did you mean cull-import? Skills that are on: cull-import.")
        // A skill that is off isn't sent.
        let disabled = AtelierSkills.getSkill(["name": .string("share-shop")], skills: [cull, off], profile: .look, clientName: "Docent")
        XCTAssertTrue(disabled.isError)
        let file = AtelierSkills.getSkill(["name": .string("cull-import"), "file": .string("keepers.md")], skills: [cull],
                                          profile: .look, clientName: "Docent")
        XCTAssertEqual(file.text, "The skill cull-import has no file keepers.md. Its files: SKILL.md, sharpness.md.")
        let unknown = AtelierSkills.getSkill(["nam": .string("cull-import")], skills: [cull], profile: .look, clientName: "Docent")
        XCTAssertTrue(unknown.isError)
        let none = AtelierSkills.getSkill(["name": .string("cull")], skills: [], profile: .look, clientName: "Docent")
        XCTAssertTrue(none.text.hasSuffix("The person has no skills turned on in Atelier."))
    }

    func testPromptsListOnlySkillsThatAreOn() {
        let prompts = AtelierSkills.prompts([cull, off])
        XCTAssertEqual(prompts.map(\.name), ["cull-import"])
        XCTAssertEqual(prompts.first?.arguments.first, MCPPrompt.Argument(name: "collection", description: "Which collection.", required: false))
        let text = AtelierSkills.promptText("cull-import", arguments: ["collection": "Best of"], skills: [cull],
                                            profile: .edit, clientName: "Docent")
        XCTAssertTrue(text?.contains("3 on Best of.") ?? false)
        XCTAssertTrue(text?.hasSuffix("More in this skill, read with get_skill: sharpness.md") ?? false)
        XCTAssertNil(AtelierSkills.promptText("share-shop", arguments: [:], skills: [off], profile: .edit, clientName: "Docent"))
    }

    func testInstructionsListTheSkillsThatAreOn() {
        XCTAssertEqual(AtelierSkills.instructions("Base.", skills: [off]), "Base.")
        let instructions = AtelierSkills.instructions("Base.", skills: [cull, off])
        XCTAssertTrue(instructions.hasPrefix("Base.\n\nSkills the person wrote for Atelier."))
        XCTAssertTrue(instructions.contains("- cull-import: Picks the keepers of each burst."))
        XCTAssertFalse(instructions.contains("share-shop"))
    }

    /// Tests never read or write the person's skills.
    @MainActor
    func testTestsUseAThrowawaySkillsFolder() {
        let real = SkillStore.defaultFolder(appName: "Atelier")
        XCTAssertNotEqual(AtelierSkills.folder.standardizedFileURL, real.standardizedFileURL)
    }

    /// Every profile can read skills.
    func testGetSkillNeedsOnlyLook() {
        XCTAssertEqual(AtelierSkills.tools.first { $0.tool.name == "get_skill" }?.profile, .look)
        XCTAssertTrue(AtelierAgentTools.getSkill.readOnly)
    }
}
