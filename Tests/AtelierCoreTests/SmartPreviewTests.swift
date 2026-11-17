import CoreImage
import Foundation
import XCTest
@testable import AtelierCore

/// AT-079d: smart previews. The white table's maths and the DNG's info everywhere; on a Mac with
/// sample RAWs (`ATELIER_SAMPLE_RAWS`), a smart preview edited in a `DevelopSession` against its
/// RAW at Develop's own settings, with timings and memory.
final class SmartPreviewTests: XCTestCase {
    /// A made-up camera whose change of white is a per-channel scale linear in mired and tint.
    private func syntheticWhite() -> CameraWhite {
        let temperatures = CameraWhite.gridTemperatures, tints = CameraWhite.gridTints
        var matrices: [[Double]] = []
        for t in temperatures {
            for n in tints {
                let m = (1e6 / t - 200) / 1000
                matrices.append([1 + m, 0, 0, 0, 1 + n / 1000, 0, 0, 0, 1 - m])
            }
        }
        return CameraWhite(camera: "Test", space: CameraWhite.currentSpace, temperatures: temperatures, tints: tints, matrices: matrices)
    }

    func testTheWhiteTableIsExactOnItsGridAndIdentityAtAsShot() {
        let white = syntheticWhite()
        let t = CameraWhite.gridTemperatures[5], n = CameraWhite.gridTints[3]
        XCTAssertEqual(white.matrix(temperature: t, tint: n), white.matrices[5 * CameraWhite.gridTints.count + 3])
        XCTAssertEqual(white.change(from: (5183, 35.9), to: 5183, tint: 35.9), WhiteMatrix3.identity)
        // Linear in mired and tint, so the bilinear lookup is exact between grid points too.
        let between = white.matrix(temperature: 4321, tint: 12)
        XCTAssertEqual(between[0], 1 + (1e6 / 4321 - 200) / 1000, accuracy: 1e-9)
        XCTAssertEqual(between[4], 1 + 12.0 / 1000, accuracy: 1e-9)
        // A change and its way back cancel.
        let there = white.change(from: (5000, 0), to: 3200, tint: 20)
        let back = white.change(from: (3200, 20), to: 5000, tint: 0)
        for (a, b) in zip(WhiteMatrix3.multiply(there, back), WhiteMatrix3.identity) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        // Outside the grid it holds the edge.
        XCTAssertEqual(white.matrix(temperature: 1000, tint: 400), white.matrix(temperature: 2000, tint: 150))
    }

    func testMatrixInverse() throws {
        let m = [2.0, 0.1, 0, 0.3, 1.2, -0.1, 0, 0.2, 0.9]
        let product = WhiteMatrix3.multiply(m, try XCTUnwrap(WhiteMatrix3.inverse(m)))
        for (a, b) in zip(product, WhiteMatrix3.identity) { XCTAssertEqual(a, b, accuracy: 1e-12) }
        XCTAssertNil(WhiteMatrix3.inverse([1, 2, 3, 2, 4, 6, 0, 0, 1]))
    }

    /// The info rides in the DNG and is read back from its IFD; any other file reads nil.
    func testTheInfoIsInTheDNG() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SmartInfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = SmartPreviewInfo(originalWidth: 6048, originalHeight: 4024, temperature: 4835.2, tint: 45.6,
                                    camera: "NIKON CORPORATION NIKON D3100", cameraMatchCurve: [0, 0.4, 1], cameraMatchSaturation: 1.1)
        let url = folder.appendingPathComponent("1.dng")
        try SmartPreviewDNG.write(rgba: [Float](repeating: 0.2, count: 300 * 200 * 4), width: 300, height: 200,
                                  neutral: SIMD3(1, 1, 1), make: "NIKON CORPORATION", model: "NIKON D3100",
                                  encoding: SmartPreviewDNG.standard, balancedCamera: true, info: info, to: url)
        XCTAssertEqual(SmartPreviewInfo.read(url), info)
        XCTAssertEqual(SmartPreviewInfo.read(url)?.originalLongEdge, 6048)
        let plain = folder.appendingPathComponent("2.dng")
        try SmartPreviewDNG.write(rgba: [Float](repeating: 0.2, count: 300 * 200 * 4), width: 300, height: 200,
                                  neutral: SIMD3(1, 1, 1), make: "X", model: "Y", encoding: .lossless16, to: plain)
        XCTAssertNil(SmartPreviewInfo.read(plain), "no info written")
        XCTAssertNil(SmartPreviewInfo.read(folder.appendingPathComponent("missing.dng")))
    }

    /// The store's files, and Discard.
    func testTheStoreKeepsOneFilePerPhoto() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SmartPreviewStore(root: root)
        XCTAssertFalse(store.has(7))
        try Data(repeating: 1, count: 1000).write(to: store.url(for: 7))
        XCTAssertEqual(store.existing(among: [7, 8]), [7])
        XCTAssertGreaterThan(store.totalBytes(), 0)
        XCTAssertEqual(store.discard([7, 8]), 1)
        XCTAssertFalse(store.has(7))
        // Discard All spares the photo Develop has open, and the white tables.
        for id in [1, 2, 3] { try Data(repeating: 1, count: 10).write(to: store.url(for: Int64(id))) }
        try Data("{}".utf8).write(to: store.whiteURL("Test"))
        XCTAssertEqual(store.usage().count, 3)
        XCTAssertEqual(store.discardAll(sparing: 2), 2)
        XCTAssertEqual(store.usage().count, 1)
        XCTAssertTrue(store.has(2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.whiteURL("Test").path))
        XCTAssertNil(SmartPreviewStore.fileID(ofName: ".4-temp.dng"))
    }

    /// On a Mac with sample RAWs: each RAW's smart preview, opened as Develop opens a photo,
    /// against the RAW at the same settings. Prints sizes, timings, memory and mean |diff|.
    func testASmartPreviewEditsLikeItsRAW() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["ATELIER_SAMPLE_RAWS"] else { throw XCTSkip("Set ATELIER_SAMPLE_RAWS") }
        let raws = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { ["nef", "cr3", "arw", "raf", "dng"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(6)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartRAW-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SmartPreviewStore(root: root)
        let renderer = DevelopRenderer.shared
        let before = RenderMemory.footprint() ?? 0
        var worst = 0.0
        for (index, raw) in raws.enumerated() {
            let id = Int64(index + 1)
            let started = Date()
            try store.make(id, from: raw, cameraMatch: renderer.cameraMatch(for: raw))
            let made = Date().timeIntervalSince(started)
            let size = try Data(contentsOf: store.url(for: id)).count
            let opening = Date()
            let preview = try XCTUnwrap(renderer.session(for: store.url(for: id), maxPixelSize: 2560))
            let opened = Date().timeIntervalSince(opening)
            let original = try XCTUnwrap(renderer.session(for: raw, maxPixelSize: 2560))
            XCTAssertNotNil(preview.smartPreview)
            XCTAssertEqual(preview.asShotTemperature, original.asShotTemperature, accuracy: 0.5)
            XCTAssertEqual(preview.renderScale, original.renderScale, accuracy: 0.01)
            print("SMART \(raw.lastPathComponent): \(size / 1024) KB, made in \(Int(made * 1000)) ms (includes the camera's white table on its first photo), opened in \(Int(opened * 1000)) ms")
            var cases: [(String, DevelopSettings)] = [("as shot", .neutral)]
            var warm = DevelopSettings.neutral; warm.temperature = 4000; cases.append(("4000K", warm))
            var cool = DevelopSettings.neutral; cool.temperature = 7500; cases.append(("7500K", cool))
            var tinted = DevelopSettings.neutral; tinted.tint = 30; cases.append(("tint +30", tinted))
            var bright = DevelopSettings.neutral; bright.exposure = 1; cases.append(("+1 EV", bright))
            for (label, settings) in cases {
                let a = Date()
                let fromPreview = try XCTUnwrap(preview.render(settings))
                let previewTime = Date().timeIntervalSince(a)
                let b = Date()
                let fromRAW = try XCTUnwrap(original.render(settings))
                let rawTime = Date().timeIntervalSince(b)
                let diff = Self.difference(fromRAW, fromPreview)
                worst = max(worst, diff.max() ?? 0)
                print("SMART \(raw.lastPathComponent) \(label): mean |diff| RGB \(diff.map { String(format: "%.1f", $0) }.joined(separator: "/")), render preview \(Int(previewTime * 1000)) ms, RAW \(Int(rawTime * 1000)) ms")
            }
        }
        let after = RenderMemory.footprint() ?? 0
        print("SMART footprint \(before / 1_048_576) MB before, \(after / 1_048_576) MB after; peak \((RenderMemory.peakFootprint() ?? 0) / 1_048_576) MB; store \(store.totalBytes() / 1024) KB")
        XCTAssertLessThan(worst, 8, "every setting within 8/255 of the RAW")
    }

    /// Mean absolute difference per channel (0-255), the smaller scaled to fit.
    static func difference(_ a: CGImage, _ b: CGImage) -> [Double] {
        let width = min(a.width, b.width), height = min(a.height, b.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let bitmap = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.interpolationQuality = .high
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        var sums = [0.0, 0.0, 0.0]
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<3 { sums[c] += abs(Double(pa[i + c]) - Double(pb[i + c])) }
        }
        return sums.map { $0 / Double(width * height) }
    }
}
