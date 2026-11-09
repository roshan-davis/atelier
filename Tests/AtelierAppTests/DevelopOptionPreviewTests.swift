import AppKit
import AtelierCore
import XCTest
@testable import AtelierApp

final class DevelopOptionPreviewTests: XCTestCase {
    @MainActor
    func testSharpeningMaskTakesOverWhileShowingBefore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Red.png")
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try CIContext().writePNGRepresentation(of: source, to: url, format: .RGBA8,
                                               colorSpace: DevelopRenderer.sRGB)
        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil).run(
            sources: [url], options: ImportOptions(buildPreviews: false)
        )
        let assetID = try XCTUnwrap(result.importedAssetIDs.first)
        let controller = DevelopController(catalog: catalog,
                                           previews: PreviewCache(rootURL: folder.appendingPathComponent("Previews")))
        controller.open(assetID)
        controller.showingBefore = true
        try await waitForImage(controller) { $0.redComponent - $0.greenComponent > 0.5 }

        controller.sliderPreview = .sharpenMask
        try await waitForImage(controller) { $0.redComponent > 0.9 && $0.greenComponent > 0.9 }

        controller.sliderPreview = nil
        try await waitForImage(controller) { $0.redComponent - $0.greenComponent > 0.5 }
        XCTAssertTrue(controller.showingBefore)
    }

    @MainActor
    private func waitForImage(_ controller: DevelopController, matching: (NSColor) -> Bool) async throws {
        var observed: NSColor?
        for _ in 0..<150 {
            if let image = controller.displayImage?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let color = NSBitmapImageRep(cgImage: image)
                   .colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB) {
                observed = color
                if matching(color) { return }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("The Develop image did not show the expected preview. Observed \(String(describing: observed)), preview \(String(describing: controller.sliderPreview))")
    }
}
