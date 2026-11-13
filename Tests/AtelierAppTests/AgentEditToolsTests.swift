import AgentActions
import AgentMCP
import AtelierActions
import AtelierCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierApp

/// AT-050d's crop, add_mask, auto and match_look run through the agent guard on real photos,
/// and the render check: an agent's burst of edits stays coalesced (numbers printed for the PR).
final class AgentEditToolsTests: XCTestCase {
    let client = AgentClient(id: "test.client#T", name: "Test", pid: 1)

    func testStudyNamesMatchTheBuiltIns() {
        XCTAssertEqual(MatchLookRules.studyNames, BuiltInLookReference.allCases.map(\.name))
    }

    // MARK: crop and add_mask

    @MainActor
    func testCropStraightenRotateAndUndo() async throws {
        let (library, ids) = try await makeLibrary(["landscape"])
        let id = ids[0]
        let server = library.agents

        let square = try call(server, "crop", ["ids": .array([.int(Int(id))]), "aspect": .string("1x1")])
        var crop = try XCTUnwrap(try library.catalog.developSettings(for: id).crop)
        XCTAssertEqual(crop.lockedAspect, 1)
        let size = CGSize(width: 1200, height: 803)
        let output = crop.outputSize(size)
        XCTAssertEqual(output.width, output.height, accuracy: 1.5)
        XCTAssertEqual(output.height, 803, accuracy: 1.5, "the largest square on a landscape photo")

        _ = try call(server, "crop", ["ids": .array([.int(Int(id))]), "angle": .number(5)])
        crop = try XCTUnwrap(try library.catalog.developSettings(for: id).crop)
        XCTAssertEqual(crop.angle, 5)
        XCTAssertTrue(crop.fits(imageAspect: 1200.0 / 803), "the crop stays on the straightened photo")
        XCTAssertEqual(crop.lockedAspect, 1)

        _ = try call(server, "crop", ["ids": .array([.int(Int(id))]), "rotate": .string("right")])
        XCTAssertEqual(try library.catalog.developSettings(for: id).crop?.quarterTurns, 1)
        let steps = try library.catalog.developHistory(for: id).steps.map(\.name)
        XCTAssertEqual(Array(steps.suffix(3)), ["Crop 1 × 1 (Test)", "Straighten 5.0° (Test)", "Rotate Right (Test)"])

        let change = try XCTUnwrap(try call(server, "crop", ["ids": .array([.int(Int(id))]), "reset": .bool(true)])
            .structured?["change"]?.stringValue)
        XCTAssertNil(try library.catalog.developSettings(for: id).crop)
        _ = try call(server, "undo_change", ["change": .string(change)], profile: .edit)
        XCTAssertEqual(try library.catalog.developSettings(for: id).crop?.quarterTurns, 1)
        _ = square
    }

    @MainActor
    func testCropNeedsEditAndRefusesBadCalls() async throws {
        let (library, ids) = try await makeLibrary(["landscape"])
        let server = library.agents
        let arguments: [String: JSONValue] = ["ids": .array([.int(Int(ids[0]))]), "aspect": .string("1x1")]
        let organize = try XCTUnwrap(server.callWrite("crop", arguments, client: client, profile: .organize))
        XCTAssertTrue(organize.isError)
        XCTAssertTrue(organize.text.contains("needs the Edit profile"), organize.text)
        let bad = try XCTUnwrap(server.callWrite("crop", ["ids": .array([.int(Int(ids[0]))]), "angle": .number(60)],
                                                 client: client, profile: .edit))
        XCTAssertTrue(bad.isError)
        XCTAssertNil(try library.catalog.developSettings(for: ids[0]).crop)
    }

    @MainActor
    func testMasksAddAndCombine() async throws {
        let (library, ids) = try await makeLibrary(["landscape", "street"])
        let server = library.agents
        let all: JSONValue = .array(ids.map { .int(Int($0)) })
        _ = try call(server, "add_mask", ["ids": all, "kind": .string("linear"), "start": .array([.number(0.5), .number(0)]),
                                          "end": .array([.number(0.5), .number(0.4)]),
                                          "settings": .array([.string("exposure=-0.5"), .string("clarity=20")])])
        for id in ids {
            let masks = try library.catalog.developSettings(for: id).masks
            XCTAssertEqual(masks.map(\.name), ["Mask 1"])
            XCTAssertEqual(masks[0][.exposure], -0.5)
            XCTAssertEqual(masks[0][.clarity], 20)
            guard case .linear(let gradient) = masks[0].components[0].shape else { return XCTFail("expected linear") }
            XCTAssertEqual(gradient.start.y, 0, accuracy: 1e-6)
            XCTAssertEqual(gradient.end.y, 0.4, accuracy: 1e-6)
        }
        _ = try call(server, "add_mask", ["ids": all, "kind": .string("radial"), "to_mask": .string("mask 1"),
                                          "combine": .string("subtract")])
        let parts = try library.catalog.developSettings(for: ids[0]).masks[0].components
        XCTAssertEqual(parts.map(\.mode), [.add, .subtract])
        XCTAssertEqual(try library.catalog.developHistory(for: ids[0]).steps.last?.name,
                       "Subtract Radial Gradient: Mask 1 (Test)")

        let missing = try XCTUnwrap(server.callWrite("add_mask", ["ids": all, "kind": .string("subject"),
                                                                  "to_mask": .string("Sky")], client: client, profile: .edit))
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("has no mask “Sky”"), missing.text)
        XCTAssertEqual(try library.catalog.developSettings(for: ids[1]).masks[0].components.count, 2)

        // On a cropped photo the agent's coordinates are the shown (cropped) photo's.
        _ = try call(server, "crop", ["ids": .array([.int(Int(ids[0]))]), "box": .array([.number(0.5), .number(0),
                                                                                          .number(0.5), .number(1)])])
        _ = try call(server, "add_mask", ["ids": .array([.int(Int(ids[0]))]), "kind": .string("object"),
                                          "box": .array([.number(0), .number(0), .number(1), .number(1)])])
        let object = try XCTUnwrap(try library.catalog.developSettings(for: ids[0]).masks.last)
        guard case .subject(let selection) = object.components[0].shape, let box = selection.box else {
            return XCTFail("expected an object box")
        }
        XCTAssertEqual(box.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(box.width, 0.5, accuracy: 0.01)
    }

    // MARK: auto and match_look

    @MainActor
    func testAutoMatchesTheAutoButton() async throws {
        let (library, ids) = try await makeLibrary(["landscape"])
        let id = ids[0]
        let url = try XCTUnwrap(try library.catalog.fileURL(for: id))
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: DevelopController.proxySize))
        let expected = try XCTUnwrap(AutoTone.apply(session: session, settings: .neutral))

        let result = try XCTUnwrap(await library.agents.callMeasuring("auto", ["ids": .array([.int(Int(id))])],
                                                                      client: client, profile: .edit))
        XCTAssertFalse(result.isError, result.text)
        let saved = try library.catalog.developSettings(for: id)
        for parameter in AutoTone.parameters {
            XCTAssertEqual(saved[parameter], expected[parameter], "\(parameter)")
        }
        XCTAssertEqual(try library.catalog.developHistory(for: id).steps.last?.name, "Auto Tone (Test)")
        XCTAssertNil(library.agentProgress)
        XCTAssertNil(library.agentJob)
    }

    @MainActor
    func testMatchLookToAStudyAndCancel() async throws {
        let (library, ids) = try await makeLibrary(["landscape", "street"])
        let all: JSONValue = .array(ids.map { .int(Int($0)) })
        let result = try XCTUnwrap(await library.agents.callMeasuring(
            "match_look", ["ids": all, "study": .string("mad max fury road - desert action"), "strength": .number(80)],
            client: client, profile: .edit))
        XCTAssertFalse(result.isError, result.text)
        for id in ids {
            XCTAssertNotEqual(try library.catalog.developSettings(for: id), .neutral)
            XCTAssertEqual(try library.catalog.developHistory(for: id).steps.last?.name,
                           "Match Look: Mad Max: Fury Road — Desert Action (Test)")
        }

        let wide = try XCTUnwrap(await library.agents.callMeasuring(
            "match_look", ["ids": all, "study": .string("The Dark Knight — Urban Night"), "areas": .string("subject")],
            client: client, profile: .edit))
        XCTAssertTrue(wide.isError)
        XCTAssertTrue(wide.text.contains("wide study"), wide.text)

        // Cancel from the status bar: nothing changes.
        let before = try ids.map { try library.catalog.developSettings(for: $0) }
        let server = library.agents
        let client = self.client
        let running = Task { @MainActor in
            await server.callMeasuring("match_look", ["ids": all, "reference": .int(Int(ids[0])), "fit": .string("each")],
                                       client: client, profile: .edit)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while library.agentJob == nil, clock.now < deadline { await Task.yield() }
        XCTAssertNotNil(library.agentProgress)
        library.agentJob?.cancel()
        let cancelled = try XCTUnwrap(await running.value)
        XCTAssertTrue(cancelled.isError)
        XCTAssertTrue(cancelled.text.contains("cancelled"), cancelled.text)
        XCTAssertEqual(try ids.map { try library.catalog.developSettings(for: $0) }, before)
        XCTAssertNil(library.agentProgress)
    }

    // MARK: The render check (AT-050d acceptance: renders stay coalesced during agent edits)

    /// An agent sends 40 edits to the open photo as fast as the guard takes them. Renders must not
    /// queue up behind them: one runs, the newest waits, and when the burst ends the photo
    /// settles within about two renders. Prints the timings for the PR.
    @MainActor
    func testAgentEditBurstOnTheOpenPhotoStaysCoalesced() async throws {
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("Big.jpg")
        try writeTestPhoto(to: source, width: 6000, height: 4000)
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("Render.atelier"))
        let imported = await Importer(catalog: catalog, previews: nil).run(sources: [source],
                                                                           options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(imported.importedAssetIDs.first)
        let develop = DevelopController(catalog: catalog, previews: PreviewCache(rootURL: folder.appendingPathComponent("P")),
                                        isPrimaryButtonPressed: { false })
        develop.open(id)
        try await waitFor(seconds: 60) { develop.sourceSize != nil && !develop.isRenderingProxy }

        let edits = 40
        let before = develop.proxyRenders.value
        let clock = ContinuousClock()
        let start = clock.now
        for index in 1...edits {
            var settings = develop.settings
            settings.exposure = Double(index) / Double(edits)
            try develop.apply(each: [id: settings], step: "Exposure (Test)")
        }
        let burst = clock.now - start
        let burstEnd = clock.now
        try await waitFor(seconds: 60) { !develop.isRenderingProxy }
        let settle = clock.now - burstEnd
        let after = develop.proxyRenders.value
        let renders = after.count - before.count
        let mean = (after.seconds - before.seconds) / Double(max(1, renders))
        let burstSeconds = Double(burst.components.attoseconds) / 1e18 + Double(burst.components.seconds)
        let settleSeconds = Double(settle.components.attoseconds) / 1e18 + Double(settle.components.seconds)
        print(String(format: "AGENT-RENDER-CHECK open photo: %d edits in %.0f ms (%.1f ms each), %d renders "
                     + "(mean %.1f ms, longest %.1f ms), settled %.0f ms after the last edit",
                     edits, burstSeconds * 1000, burstSeconds * 1000 / Double(edits), renders, mean * 1000,
                     after.longest * 1000, settleSeconds * 1000))
        XCTAssertGreaterThan(renders, 0)
        XCTAssertLessThanOrEqual(renders, edits)
        // Coalesced: no more renders than the burst had time for, plus the one in flight and the last.
        XCTAssertLessThanOrEqual(Double(renders), burstSeconds / max(mean, 0.001) + 2)
        // No backlog: after the last edit, at most the render in flight and one follow-up.
        XCTAssertLessThan(settleSeconds, 2 * max(after.longest, mean) + 0.5)
        XCTAssertEqual(develop.settings.exposure, 1)
        XCTAssertEqual(try catalog.developSettings(for: id).exposure, 1)
    }

    /// The same edits on photos that aren't open: their preview refreshes run two at a time and
    /// an older look's refresh is skipped once a newer one is saved.
    @MainActor
    func testAgentEditsOnOtherPhotosRefreshEachPreviewOnce() async throws {
        let folder = try temporaryFolder()
        var sources: [URL] = []
        for index in 0..<8 {
            let url = folder.appendingPathComponent("Photo\(index).jpg")
            try writeTestPhoto(to: url, width: 3000, height: 2000)
            sources.append(url)
        }
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("Refresh.atelier"))
        let imported = await Importer(catalog: catalog, previews: nil).run(sources: sources,
                                                                           options: ImportOptions(buildPreviews: false))
        let ids = imported.importedAssetIDs
        XCTAssertEqual(ids.count, 8)
        let develop = DevelopController(catalog: catalog, previews: PreviewCache(rootURL: folder.appendingPathComponent("P")),
                                        isPrimaryButtonPressed: { false })
        let rounds = 3
        let clock = ContinuousClock()
        let start = clock.now
        for round in 1...rounds {
            var updated: [Int64: DevelopSettings] = [:]
            for id in ids {
                var settings = try catalog.developSettings(for: id)
                settings.exposure = Double(round) / 4
                updated[id] = settings
            }
            try develop.apply(each: updated, step: "Exposure (Test)")
        }
        let asked = ids.count * rounds
        try await waitFor(seconds: 120) {
            let tally = develop.refreshRenders.value
            return tally.count + tally.skipped >= asked
        }
        let took = clock.now - start
        let tally = develop.refreshRenders.value
        print(String(format: "AGENT-RENDER-CHECK other photos: %d edits on %d photos, %d refresh renders (mean %.1f ms), "
                     + "%d skipped as superseded, all done in %.0f ms",
                     asked, ids.count, tally.count, tally.meanMS, tally.skipped,
                     (Double(took.components.attoseconds) / 1e18 + Double(took.components.seconds)) * 1000))
        XCTAssertEqual(tally.count + tally.skipped, asked)
        XCTAssertGreaterThanOrEqual(tally.count, ids.count, "every photo's last look is rendered")
        XCTAssertLessThan(tally.count, asked, "an older look waiting behind a newer one is skipped")
    }

    // MARK: Helpers

    @MainActor
    private func call(_ server: AgentServer, _ tool: String, _ arguments: [String: JSONValue],
                      profile: AgentProfile = .edit, file: StaticString = #filePath,
                      line: UInt = #line) throws -> MCPToolResult {
        let result = try XCTUnwrap(server.callWrite(tool, arguments, client: client, profile: profile),
                                   file: file, line: line)
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return result
    }

    @MainActor
    private func makeLibrary(_ fixtures: [String]) async throws -> (LibraryModel, [Int64]) {
        let folder = try temporaryFolder()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures")
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("AgentEdit.atelier"))
        var ids: [Int64] = []
        for fixture in fixtures {
            // A copy each, so the fixtures are never touched.
            let copy = folder.appendingPathComponent(fixture + ".jpg")
            try FileManager.default.copyItem(at: directory.appendingPathComponent(fixture + ".jpg"), to: copy)
            let imported = await Importer(catalog: catalog, previews: nil).run(sources: [copy],
                                                                               options: ImportOptions(buildPreviews: false))
            ids.append(try XCTUnwrap(imported.importedAssetIDs.first))
        }
        let saved = UserDefaults.standard.object(forKey: "matchLook.options")
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: "matchLook.options") }
        return (LibraryModel(catalog: catalog), ids)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A photo-sized JPEG with gradients and fine detail, so renders and decodes take real time.
    private func writeTestPhoto(to url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors = [CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1), CGColor(red: 0.9, green: 0.6, blue: 0.3, alpha: 1)]
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.15))
        for index in stride(from: 0, to: width, by: 37) {
            context.fill(CGRect(x: index, y: (index * 7) % height, width: 9, height: height / 3))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                                        1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    @MainActor
    private func waitFor(seconds: Int, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while !condition() {
            guard clock.now < deadline else { return XCTFail("timed out after \(seconds) s") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
