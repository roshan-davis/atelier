import AtelierCore
import Foundation
import XCTest
@testable import AtelierApp

final class DevelopPointerEditTests: XCTestCase {
    @MainActor
    func testPauseKeepsPointCurveDragInOneUndoStep() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Pixel.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD0sAAAAASUVORK5CYII="))
        try png.write(to: source)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil).run(
            sources: [source], options: ImportOptions(buildPreviews: false)
        )
        let id = try XCTUnwrap(result.importedAssetIDs.first)
        // Exercise history and persistence without leaving a preview render in flight.
        try FileManager.default.moveItem(at: source, to: folder.appendingPathComponent("Offline.png"))
        let previews = PreviewCache(rootURL: folder.appendingPathComponent("Previews"))
        var mouseDown = true
        let develop = DevelopController(catalog: catalog, previews: previews, isPrimaryButtonPressed: { mouseDown })
        develop.open(id)
        let initial = develop.settings
        let initialSteps = develop.history.steps.count
        let persisted = try catalog.developSettings(for: id)
        func points(_ middle: Double) -> [DevelopSettings.CurvePoint] {
            [.init(x: 0, y: 0), .init(x: 0.5, y: middle), .init(x: 1, y: 1)]
        }

        develop.beginPointerEdit()
        develop.setPoints(points(0.6), for: .rgb)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(develop.history.steps.count, initialSteps)
        XCTAssertEqual(try catalog.developSettings(for: id), persisted)

        develop.setPoints(points(0.7), for: .rgb)
        mouseDown = false
        develop.endPointerEdit()
        XCTAssertEqual(develop.history.steps.count, max(initialSteps, 1) + 1)
        XCTAssertEqual(try catalog.developSettings(for: id).points(for: .rgb), points(0.7))
        develop.undo()
        XCTAssertEqual(develop.settings, initial)
    }
}
