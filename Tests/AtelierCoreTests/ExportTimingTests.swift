import Foundation
import XCTest
@testable import AtelierCore

/// AT-076 P3: how long Export takes per photo on real RAWs, the memory the process peaks at, and
/// what it keeps right after and 3 s later (Core Image hands its memory back within about 3 s). Prints EXPORTBENCH lines. Opt-in, one setting per run so each peak
/// is its own: `ATELIER_EXPORT_BENCH=<full-jpeg|2048-jpeg|full-tiff> [ATELIER_EXPORT_INFLIGHT=1|2]
/// ATELIER_SAMPLE_RAWS=/folder/of/raws swift test --filter ExportTimingTests`.
final class ExportTimingTests: XCTestCase {
    func testExportTime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let variant = environment["ATELIER_EXPORT_BENCH"], let folder = environment["ATELIER_SAMPLE_RAWS"] else {
            throw XCTSkip("Set ATELIER_EXPORT_BENCH and ATELIER_SAMPLE_RAWS to time Export.")
        }
        let raws = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { FilePairs.isRaw($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(raws.isEmpty, "no RAWs in \(folder)")

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AtelierExportBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let catalog = try Catalog()
        let imported = await Importer(catalog: catalog, previews: nil)
            .run(sources: raws, options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(imported.failures, [])
        let ids = imported.assetIDsBySource.sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }.map(\.value)
        var edit = DevelopSettings.neutral
        edit.exposure = 0.3
        edit.contrast = 15
        edit.highlights = -40
        edit.shadows = 30
        edit.vibrance = 20
        try catalog.applyDevelopSettings(edit, to: ids, step: "Bench")

        var settings = ExportSettings(destination: work.appendingPathComponent("Out", isDirectory: true))
        switch variant {
        case "full-jpeg": settings.format = .jpeg
        case "2048-jpeg": settings.format = .jpeg; settings.longEdge = 2048; settings.sharpening = .screen
        case "full-tiff": settings.format = .tiff
        default: return XCTFail("unknown variant \(variant)")
        }

        let inFlight = Int(environment["ATELIER_EXPORT_INFLIGHT"] ?? "") ?? 2
        let before = RenderMemory.footprint() ?? 0
        let began = Date()
        let result = await Exporter(catalog: catalog, renderer: .shared, photosInFlight: inFlight)
            .run(assetIDs: ids, settings: settings)
        let total = Date().timeIntervalSince(began) * 1000
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.exported.count, ids.count)
        let peak = RenderMemory.peakFootprint() ?? 0, after = RenderMemory.footprint() ?? 0
        RenderMemory.shared.clear(because: "bench")
        let cleared = RenderMemory.footprint() ?? 0
        try await Task.sleep(for: .seconds(3))
        let settled = RenderMemory.footprint() ?? 0
        let perPhoto = total / Double(ids.count)
        let mb: (UInt64) -> UInt64 = { $0 / 1_048_576 }
        print("EXPORTBENCH variant=\(variant) in_flight=\(inFlight) photos=\(ids.count) total_ms=\(Int(total)) "
            + "per_photo_ms=\(Int(perPhoto)) before_mb=\(mb(before)) peak_mb=\(mb(peak)) after_mb=\(mb(after)) "
            + "after_clear_mb=\(mb(cleared)) settled_3s_mb=\(mb(settled))")
    }
}
