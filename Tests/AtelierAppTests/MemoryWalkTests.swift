import AppKit
import AtelierCore
import SwiftUI
import XCTest
@testable import AtelierApp

/// Memory while clicking through many real photos in Loupe and Develop (the hosted real views,
/// in a window never put on screen): the process's footprint after each photo and its peak, so
/// memory held for a photo that was left shows as growth. Needs ATELIER_MEMORY_FOLDER (a folder of
/// at least ATELIER_MEMORY_COUNT RAWs, 30 by default); skipped without it. Run each test in its own
/// process (`--filter MemoryWalkTests/testLoupe…`) so the peak is that walk's.
@MainActor
final class MemoryWalkTests: XCTestCase {
    private func walk(develop: Bool) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["ATELIER_MEMORY_FOLDER"] else { throw XCTSkip("ATELIER_MEMORY_FOLDER not set") }
        let count = Int(env["ATELIER_MEMORY_COUNT"] ?? "30") ?? 30
        let dwell = Double(env["ATELIER_MEMORY_DWELL"] ?? "1.2") ?? 1.2
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.uppercased() == "NEF" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(count)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryWalk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let catalog = try Catalog(packageURL: work.appendingPathComponent("Walk.atelier"))
        let previews = PreviewCache(rootURL: try XCTUnwrap(catalog.previewsURL))
        previews.discardIfOutdated()
        var ids: [Int64] = []
        for file in files {
            let imported = await Importer(catalog: catalog, previews: nil).run(sources: [file], options: ImportOptions(buildPreviews: false))
            let id = try XCTUnwrap(imported.importedAssetIDs.first)
            try previews.generate(for: id, from: file)
            ids.append(id)
        }
        let model = LibraryModel(catalog: catalog)
        try await waitFor(seconds: 30) { model.rows.count >= ids.count }
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1512, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        if develop {
            window.contentView = NSHostingView(rootView: DevelopImageView(develop: model.develop).environmentObject(model))
        } else {
            window.contentView = NSHostingView(rootView: LoupeView(zoom: model.zoomState).environmentObject(model))
        }
        addTeardownBlock { @MainActor in window.close() }
        model.focusedID = ids[0]
        model.mode = develop ? .develop : .loupe
        try await Task.sleep(for: .seconds(2))
        let start = RenderMemory.footprint() ?? 0
        var footprints: [UInt64] = []
        for id in ids {
            model.focusedID = id
            try await Task.sleep(for: .seconds(dwell))
            footprints.append(RenderMemory.footprint() ?? 0)
        }
        let mb = { (value: UInt64) in Int(value >> 20) }
        let first10 = footprints.prefix(10).map(mb), last10 = footprints.suffix(10).map(mb)
        print("MEMORY \(develop ? "Develop" : "Loupe") walk of \(ids.count) photos (\(dwell) s each): start \(mb(start)) MB; "
              + "after photo 1 \(mb(footprints.first ?? 0)) MB, 10 \(mb(footprints[min(9, footprints.count - 1)])) MB, "
              + "20 \(mb(footprints[min(19, footprints.count - 1)])) MB, \(ids.count) \(mb(footprints.last ?? 0)) MB; "
              + "median of first 10 \(first10.sorted()[first10.count / 2]) MB, of last 10 \(last10.sorted()[last10.count / 2]) MB; "
              + "peak \(mb(RenderMemory.peakFootprint() ?? 0)) MB")
        // Leaving the mode lets go of what it held.
        model.mode = .grid
        try await Task.sleep(for: .seconds(4))
        print("MEMORY \(develop ? "Develop" : "Loupe") after leaving: \(mb(RenderMemory.footprint() ?? 0)) MB")
    }

    func testLoupeWalk() async throws { try await walk(develop: false) }
    func testDevelopWalk() async throws { try await walk(develop: true) }

    private func waitFor(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
