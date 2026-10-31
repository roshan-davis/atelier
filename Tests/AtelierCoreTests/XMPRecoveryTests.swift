import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class XMPRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("XMPRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func image(_ name: String = "Photo.jpg") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func edited() -> DevelopSettings {
        var settings = DevelopSettings()
        settings.exposure = 0.6
        settings.contrast = 15
        settings.disabledPanels = [.detail]
        var mask = DevelopSettings.Mask(name: "Sky & <light>", components: [
            .init(.linear(.init(start: .init(x: 0.5, y: 0), end: .init(x: 0.5, y: 0.7)))),
            .init(.luminance(.init(low: 20, high: 90)), mode: .intersect)
        ])
        mask[.exposure] = -0.4
        settings.masks = [mask]
        return settings
    }

    private func importPhoto(_ file: URL, into catalog: Catalog, options: ImportOptions? = nil) async throws -> Int64 {
        let result = await Importer(catalog: catalog, previews: nil).run(sources: [file],
            options: options ?? ImportOptions(buildPreviews: false))
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        return try XCTUnwrap(result.importedAssetIDs.first)
    }

    func testCatalogLossRecoveryWinsOverPresetAndPreservesOriginalAndRender() async throws {
        let file = try image()
        let original = try Data(contentsOf: file)
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        let settings = edited()
        try catalog.saveDevelopSettings(settings, for: id)
        XCTAssertTrue(try XCTUnwrap(catalog.detail(for: id)).metadata.xmpDirty)
        let written = try catalog.writeXMPSidecars()
        XCTAssertEqual(written.written, 1)
        XCTAssertTrue(written.failures.isEmpty)
        XCTAssertFalse(try XCTUnwrap(catalog.detail(for: id)).metadata.xmpDirty)
        let recoveredCatalog = try Catalog()
        var presetSettings = DevelopSettings()
        presetSettings.exposure = -2
        let preset = DevelopPreset(name: "Import", parts: [.exposure], settings: presetSettings)
        let recoveredID = try await importPhoto(file, into: recoveredCatalog,
            options: ImportOptions(buildPreviews: false, developPreset: preset))
        let recovered = try recoveredCatalog.developSettings(for: recoveredID)
        XCTAssertEqual(recovered, settings)
        let history = try recoveredCatalog.developHistory(for: recoveredID)
        XCTAssertEqual(history, try catalog.developHistory(for: id))
        XCTAssertTrue(history.snapshots.isEmpty)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 32))
        let before = try XCTUnwrap(session.render(settings))
        let after = try XCTUnwrap(session.render(recovered))
        XCTAssertEqual(before.dataProvider?.data as Data?, after.dataProvider?.data as Data?)
        XCTAssertEqual(try Data(contentsOf: file), original)
        // Reimport must preserve existing catalog edits even after the sidecar changes.
        try recoveredCatalog.saveDevelopSettings(.neutral, for: recoveredID)
        let again = await Importer(catalog: recoveredCatalog, previews: nil)
            .run(sources: [file], options: ImportOptions(buildPreviews: false, developPreset: preset))
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(try recoveredCatalog.developSettings(for: recoveredID), .neutral)
    }

    func testSharedSidecarKeepsRAWJPEGEntriesAndForeignTags() throws {
        let raw = directory.appendingPathComponent("Pair.NEF")
        let jpeg = directory.appendingPathComponent("Pair.JPG")
        let sidecar = XMPSidecar.sidecarURL(for: raw)
        let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:foreign="https://example.org/photo/"><foreign:Note>keep me</foreign:Note></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        try Data(packet.utf8).write(to: sidecar)
        let rawSettings = edited()
        var jpegSettings = edited()
        jpegSettings.exposure = -1
        try XMPSidecar.write(XMPFields(rating: 3), toSidecar: sidecar, develop: rawSettings, filename: raw.lastPathComponent)
        try XMPSidecar.write(XMPFields(rating: 4), toSidecar: sidecar, develop: jpegSettings, filename: jpeg.lastPathComponent)
        XCTAssertEqual(try XMPSidecar.readDevelop(for: raw), rawSettings)
        XCTAssertEqual(try XMPSidecar.readDevelop(for: jpeg), jpegSettings)
        XCTAssertNil(try XMPSidecar.readDevelop(for: directory.appendingPathComponent("Pair.tif")))
        let metadata = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(contentsOf: sidecar) as CFData))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata, nil, "foreign:Note" as CFString) as String?, "keep me")
        // Metadata-only callers must retain both Develop entries.
        try XMPSidecar.write(XMPFields(rating: 5), toSidecar: sidecar)
        XCTAssertEqual(try XMPSidecar.readDevelop(for: raw), rawSettings)
        XCTAssertEqual(try XMPSidecar.readDevelop(for: jpeg), jpegSettings)
    }

    func testInvalidOrFutureDataIsPreservedAndImportReportsProblem() async throws {
        let file = try image()
        let sidecar = XMPSidecar.sidecarURL(for: file)
        for value in ["<atelier:DevelopRecovery>truncated", recoveryXML(format: 99, settings: #"{"schemaVersion":3}"#),
                      recoveryXML(settings: #"{"schemaVersion":999,"exposure":1}"#),
                      recoveryXML(settings: #"{"schemaVersion":3,"masks":"broken"}"#),
                      recoveryXML(settings: #"{"schemaVersion":3,"profile":"unknown"}"#),
                      recoveryXML(settings: #"{"schemaVersion":3,"masks":[{"components":[{"kind":"sky"}]}]}"#)] {
            try Data(value.utf8).write(to: sidecar)
            let bytes = try Data(contentsOf: sidecar)
            XCTAssertThrowsError(try XMPSidecar.readDevelop(for: file))
            XCTAssertThrowsError(try XMPSidecar.write(XMPFields(), toSidecar: sidecar,
                                                     develop: .neutral, filename: file.lastPathComponent))
            let result = await Importer(catalog: try Catalog(), previews: nil)
                .run(sources: [file], options: ImportOptions(buildPreviews: false))
            XCTAssertEqual(result.imported, 0)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        }
    }

    func testOldMetadataOnlyAndOldSettingsStillImport() async throws {
        let file = try image()
        let sidecar = XMPSidecar.sidecarURL(for: file)
        try XMPSidecar.write(XMPFields(rating: 4), toSidecar: sidecar)
        XCTAssertNil(try XMPSidecar.readDevelop(for: file))
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        XCTAssertEqual(try catalog.developSettings(for: id), .neutral)
        XCTAssertEqual(try catalog.detail(for: id)?.metadata.rating, 4)
        try Data(recoveryXML(settings: #"{"schemaVersion":1,"exposure":0.5}"#).utf8).write(to: sidecar)
        let old = try XCTUnwrap(XMPSidecar.readDevelop(for: file))
        XCTAssertEqual(old.exposure, 0.5)
        XCTAssertTrue(old.masks.isEmpty)
    }

    func testCopiedImportKeepsRecoveredEditsAndCanWriteAtDestination() async throws {
        let file = try image()
        let sidecar = XMPSidecar.sidecarURL(for: file)
        let settings = edited()
        var history = DevelopHistory()
        history.record("Before copy", settings: settings, previous: .neutral)
        history.snapshots = [.init(name: "Copied snapshot", date: Date(timeIntervalSince1970: 100), settings: settings)]
        try XMPSidecar.write(XMPFields(), toSidecar: sidecar, develop: settings, filename: file.lastPathComponent, history: history)
        let catalog = try Catalog()
        let destination = directory.appendingPathComponent("Copies")
        let id = try await importPhoto(file, into: catalog,
            options: ImportOptions(mode: .copy(destinationRoot: destination, eventName: "Recovery"), buildPreviews: false))
        XCTAssertEqual(try catalog.developSettings(for: id), settings)
        XCTAssertEqual(try catalog.writeXMPSidecars().written, 1)
        let copied = try XCTUnwrap(catalog.fileURL(for: id))
        XCTAssertNotEqual(copied, file)
        XCTAssertEqual(try XMPSidecar.readDevelop(for: copied), settings)
        XCTAssertEqual(try XMPSidecar.readDevelopRecovery(for: copied)?.history, try catalog.developHistory(for: id))
    }

    func testResetWritesNeutralInsteadOfResurrectingOldEdits() async throws {
        let file = try image()
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        try catalog.saveDevelopSettings(edited(), for: id)
        _ = try catalog.writeXMPSidecars()
        try catalog.saveDevelopSettings(.neutral, for: id)
        XCTAssertEqual(try catalog.writeXMPSidecars().written, 1)
        XCTAssertEqual(try XMPSidecar.readDevelop(for: file), .neutral)
    }

    func testAllMaskKindsAndGeometrySurviveRecovery() throws {
        let file = directory.appendingPathComponent("Photo.jpg")
        var settings = edited()
        var mask = DevelopSettings.Mask(name: "All kinds", components: [
            .init(.brush([.init(points: [.init(x: 0.2, y: 0.3), .init(x: 0.4, y: 0.5)], size: 0.1)])),
            .init(.radial(.init(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.3))),
            .init(.subject(.init(feather: 25))),
            .init(.subject(.init(box: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))), mode: .subtract)
        ])
        mask.isHidden = true
        mask.inverted = true
        mask.amount = 150
        mask[.temperature] = 20
        settings.masks.append(mask)
        var crop = DevelopSettings.Crop()
        crop.quarterTurns = 1
        crop.flipHorizontal = true
        crop.angle = 3
        settings.crop = crop
        try XMPSidecar.write(XMPFields(), toSidecar: XMPSidecar.sidecarURL(for: file),
                             develop: settings, filename: file.lastPathComponent)
        XCTAssertEqual(try XMPSidecar.readDevelop(for: file), settings)
    }

    func testConcurrentPairedWritesKeepBothEntries() async throws {
        let raw = directory.appendingPathComponent("Photo.NEF")
        let jpeg = directory.appendingPathComponent("Photo.jpg")
        let rawSettings = edited()
        var jpegSettings = edited()
        jpegSettings.exposure = -1
        let jobs = [(raw, rawSettings), (jpeg, jpegSettings)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (file, settings) in jobs {
                group.addTask {
                    try XMPSidecar.write(XMPFields(), toSidecar: XMPSidecar.sidecarURL(for: file),
                                         develop: settings, filename: file.lastPathComponent, history: DevelopHistory())
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try XMPSidecar.readDevelop(for: raw), rawSettings)
        XCTAssertEqual(try XMPSidecar.readDevelop(for: jpeg), jpegSettings)
        XCTAssertEqual(try XMPSidecar.readDevelopRecovery(for: raw)?.history, DevelopHistory())
        XCTAssertEqual(try XMPSidecar.readDevelopRecovery(for: jpeg)?.history, DevelopHistory())
    }

    func testFailedAndOfflineWritesStayDirty() async throws {
        let file = try image()
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        try catalog.saveDevelopSettings(edited(), for: id)
        let sidecar = XMPSidecar.sidecarURL(for: file)
        try Data("broken sidecar".utf8).write(to: sidecar)
        let result = try catalog.writeXMPSidecars()
        XCTAssertEqual(result.written, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(try XCTUnwrap(catalog.detail(for: id)).metadata.xmpDirty)
        try await catalog.writer.write { db in
            try db.execute(sql: "UPDATE volume SET isOnline = 0, mountPath = NULL")
        }
        let offline = try catalog.writeXMPSidecars()
        XCTAssertEqual(offline.offline, 1)
        XCTAssertTrue(try XCTUnwrap(catalog.detail(for: id)).metadata.xmpDirty)
    }

    func testMetadataOnlyWriteDoesNotSuppressFreshImportPreset() async throws {
        let file = try image()
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        try catalog.setRating(4, for: [id])
        XCTAssertEqual(try catalog.writeXMPSidecars().written, 1)
        XCTAssertNil(try XMPSidecar.readDevelop(for: file))
        var settings = DevelopSettings()
        settings.exposure = 1.2
        let preset = DevelopPreset(name: "Fresh import", parts: [.exposure], settings: settings)
        let restored = try Catalog()
        let restoredID = try await importPhoto(file, into: restored,
            options: ImportOptions(buildPreviews: false, developPreset: preset))
        XCTAssertEqual(try restored.developSettings(for: restoredID).exposure, 1.2)
        XCTAssertEqual(try restored.detail(for: restoredID)?.metadata.rating, 4)
    }

    func testUnreadableForeignSidecarDoesNotBlockImportOrOverwriteIt() async throws {
        let file = try image()
        let sidecar = XMPSidecar.sidecarURL(for: file)
        let foreign = Data("<foreign:metadata>truncated foreign data".utf8)
        try foreign.write(to: sidecar)
        XCTAssertNil(try XMPSidecar.readDevelop(for: file))
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        XCTAssertEqual(try catalog.developSettings(for: id), .neutral)
        XCTAssertThrowsError(try XMPSidecar.write(XMPFields(), toSidecar: sidecar))
        XCTAssertEqual(try Data(contentsOf: sidecar), foreign)
        // Recognition also protects a damaged UTF-16 Atelier packet.
        try "<atelier:DevelopRecovery>broken".data(using: .utf16)!.write(to: sidecar)
        XCTAssertThrowsError(try XMPSidecar.readDevelop(for: file))
    }

    func testExistingReferenceIsSkippedBeforeDamagedRecoveryIsRead() async throws {
        let file = try image()
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        try catalog.saveDevelopSettings(edited(), for: id)
        let before = try catalog.developSettings(for: id)
        try Data("<atelier:DevelopRecovery>truncated".utf8).write(to: XMPSidecar.sidecarURL(for: file))
        let result = await Importer(catalog: catalog, previews: nil)
            .run(sources: [file], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try catalog.developSettings(for: id), before)
    }

    func testImportAutoWriteCandidatesExcludeUntouchedPhotos() async throws {
        let file = try image()
        let untouched = await Importer(catalog: try Catalog(), previews: nil)
            .run(sources: [file], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(untouched.imported, 1)
        XCTAssertTrue(untouched.developedAssetIDs.isEmpty)
        var settings = DevelopSettings()
        settings.exposure = 0.5
        let preset = DevelopPreset(name: "Preset", parts: [.exposure], settings: settings)
        let presetImport = await Importer(catalog: try Catalog(), previews: nil)
            .run(sources: [file], options: ImportOptions(buildPreviews: false, developPreset: preset))
        XCTAssertEqual(presetImport.developedAssetIDs, presetImport.importedAssetIDs)
        try XMPSidecar.write(XMPFields(), toSidecar: XMPSidecar.sidecarURL(for: file),
                             develop: .neutral, filename: file.lastPathComponent)
        let recovered = await Importer(catalog: try Catalog(), previews: nil)
            .run(sources: [file], options: ImportOptions(buildPreviews: false))
        XCTAssertEqual(recovered.developedAssetIDs, recovered.importedAssetIDs)
    }

    func testHistoryRedoAndSnapshotsRecoverTogether() async throws {
        let file = try image()
        let original = try Data(contentsOf: file)
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        var history = DevelopHistory()
        let settings = edited()
        var later = settings
        later.exposure = 1.8
        history.record("First edit", settings: settings, previous: .neutral)
        history.record("Later edit", settings: later, previous: settings)
        history.position = 1
        history.snapshots = [.init(name: "Sky & <light>", date: Date(timeIntervalSince1970: 100), settings: later)]
        try catalog.saveDevelop(settings, history: history, for: id)
        let expected = try catalog.developHistory(for: id)
        XCTAssertEqual(try catalog.writeXMPSidecars().written, 1)
        let restored = try Catalog()
        let restoredID = try await importPhoto(file, into: restored)
        let recovered = try restored.developHistory(for: restoredID)
        XCTAssertEqual(recovered, expected)
        XCTAssertTrue(recovered.canUndo)
        XCTAssertTrue(recovered.canRedo)
        XCTAssertEqual(recovered.steps[recovered.position + 1].settings, later)
        XCTAssertEqual(try Data(contentsOf: file), original)
        // Snapshot rename/update/delete and history clearing do not require a settings change.
        var changed = recovered
        changed.snapshots[0].name = "Renamed"
        changed.snapshots[0].settings = settings
        try restored.saveDevelop(settings, history: changed, for: restoredID)
        XCTAssertTrue(try XCTUnwrap(restored.detail(for: restoredID)).metadata.xmpDirty)
        XCTAssertEqual(try restored.writeXMPSidecars().written, 1)
        XCTAssertEqual(try XMPSidecar.readDevelopRecovery(for: file)?.history, changed)
        changed.snapshots.removeAll()
        changed.clear()
        try restored.saveDevelop(settings, history: changed, for: restoredID)
        XCTAssertEqual(try restored.writeXMPSidecars().written, 1)
        XCTAssertEqual(try XMPSidecar.readDevelopRecovery(for: file)?.history, changed)
    }

    func testSettingsOnlyCompatibilityAndLegacyCatalogHistory() async throws {
        let file = try image()
        let settings = edited()
        try XMPSidecar.write(XMPFields(), toSidecar: XMPSidecar.sidecarURL(for: file),
                             develop: settings, filename: file.lastPathComponent)
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog)
        XCTAssertEqual(try catalog.developHistory(for: id).steps.map(\.name), ["Recovered from XMP"])
        try await catalog.writer.write { db in
            try db.execute(sql: "UPDATE developSettings SET historyJson = '[]'")
        }
        XCTAssertEqual(try catalog.writeXMPSidecars(for: [id]).written, 1)
        XCTAssertEqual(try XMPSidecar.readDevelopRecovery(for: file)?.history, DevelopHistory())
    }

    func testHistoryValidationRejectsCorruptionRatherThanClampingOrDropping() throws {
        let settings = edited()
        var history = DevelopHistory()
        history.record("Edit", settings: settings, previous: .neutral)
        let entry = HistoryRecovery.Entry(settings: try settings.encoded(), history: try history.encoded())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(entry.history.utf8)) as? [String: Any])
        object["position"] = 999
        var invalid = entry
        invalid.history = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertThrowsError(try HistoryRecovery.history(invalid, settings: settings))
        object["position"] = 1
        var steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        steps[0]["settings"] = ["schemaVersion": 3, "masks": "broken"]
        object["steps"] = steps
        invalid.history = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertThrowsError(try HistoryRecovery.history(invalid, settings: settings))
        XCTAssertThrowsError(try HistoryRecovery.history(entry, settings: .neutral))
        history.snapshots = [.init(name: "A", settings: settings)]
        history.snapshots.append(history.snapshots[0])
        invalid.history = try history.encoded()
        XCTAssertThrowsError(try HistoryRecovery.history(invalid, settings: settings))
        XCTAssertThrowsError(try HistoryRecovery.packet(#"{"formatVersion":99,"files":{}}"#))
    }

    func testStaleHistoryFromOlderWriterBlocksImportAndOverwrite() async throws {
        let file = try image()
        let sidecar = XMPSidecar.sidecarURL(for: file)
        let settings = edited()
        var history = DevelopHistory()
        history.record("Edit", settings: settings, previous: .neutral)
        try XMPSidecar.write(XMPFields(), toSidecar: sidecar, develop: settings,
                             filename: file.lastPathComponent, history: history)
        let metadata = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(contentsOf: sidecar) as CFData))
        let mutable = try XCTUnwrap(CGImageMetadataCreateMutableCopy(metadata))
        CGImageMetadataRegisterNamespaceForPrefix(mutable, XMPSidecar.atelierNamespace as CFString, "atelier" as CFString, nil)
        let packet = DevelopRecovery.Packet(files: [file.lastPathComponent: try DevelopSettings.neutral.encoded()])
        let json = String(decoding: try JSONEncoder().encode(packet), as: UTF8.self)
        CGImageMetadataSetValueWithPath(mutable, nil, DevelopRecovery.path as CFString, json as CFString)
        try XCTUnwrap(CGImageMetadataCreateXMPData(mutable, nil) as Data?).write(to: sidecar)
        let original = try Data(contentsOf: sidecar)
        let result = await Importer(catalog: try Catalog(), previews: nil).run(sources: [file], options: .init(buildPreviews: false))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.imported, 0)
        XCTAssertThrowsError(try XMPSidecar.write(XMPFields(), toSidecar: sidecar,
            develop: settings, filename: file.lastPathComponent, history: history))
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
    }

    func testPairedHistoryWritesPreserveSiblingAndSettingsOnlyCallerRemovesOwnHistory() throws {
        let raw = directory.appendingPathComponent("Pair.NEF")
        let jpeg = directory.appendingPathComponent("Pair.JPG")
        var history = DevelopHistory()
        history.snapshots = [.init(name: "Neutral", date: Date(timeIntervalSince1970: 100), settings: .neutral)]
        for file in [raw, jpeg] {
            try XMPSidecar.write(XMPFields(), toSidecar: XMPSidecar.sidecarURL(for: file),
                develop: .neutral, filename: file.lastPathComponent, history: history)
        }
        try XMPSidecar.write(XMPFields(rating: 4), toSidecar: XMPSidecar.sidecarURL(for: raw))
        XCTAssertEqual(try XMPSidecar.readDevelopRecovery(for: raw)?.history, history)
        try XMPSidecar.write(XMPFields(), toSidecar: XMPSidecar.sidecarURL(for: raw),
            develop: edited(), filename: raw.lastPathComponent)
        XCTAssertNil(try XMPSidecar.readDevelopRecovery(for: raw)?.history)
        XCTAssertEqual(try XMPSidecar.readDevelopRecovery(for: jpeg)?.history, history)
    }

    func testDamagedAndFutureHistoryImportPreservesSidecarAndRejectsPreset() async throws {
        let file = try image()
        let sidecar = XMPSidecar.sidecarURL(for: file)
        let settings = edited()
        let entry = HistoryRecovery.Entry(settings: try settings.encoded(), history: "broken history")
        let corrupt = String(decoding: try JSONEncoder().encode(HistoryRecovery.Packet(files: [file.lastPathComponent: entry])), as: UTF8.self)
        for value in [corrupt, #"{"formatVersion":99,"files":{}}"#] {
            try? FileManager.default.removeItem(at: sidecar)
            try XMPSidecar.write(XMPFields(), toSidecar: sidecar, develop: settings, filename: file.lastPathComponent)
            let metadata = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(contentsOf: sidecar) as CFData))
            let mutable = try XCTUnwrap(CGImageMetadataCreateMutableCopy(metadata))
            CGImageMetadataRegisterNamespaceForPrefix(mutable, XMPSidecar.atelierNamespace as CFString, "atelier" as CFString, nil)
            CGImageMetadataSetValueWithPath(mutable, nil, HistoryRecovery.path as CFString, value as CFString)
            try XCTUnwrap(CGImageMetadataCreateXMPData(mutable, nil) as Data?).write(to: sidecar)
            let bytes = try Data(contentsOf: sidecar)
            let preset = DevelopPreset(name: "Do not substitute", parts: [.exposure], settings: .neutral)
            let result = await Importer(catalog: try Catalog(), previews: nil).run(sources: [file],
                options: .init(buildPreviews: false, developPreset: preset))
            XCTAssertEqual(result.imported, 0)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertThrowsError(try XMPSidecar.write(XMPFields(), toSidecar: sidecar,
                develop: settings, filename: file.lastPathComponent, history: DevelopHistory()))
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        }
    }

    func testCollisionRenamedCopyRecoversHistoryAndWritesDestinationKey() async throws {
        let file = try image()
        let options = ImportOptions(mode: .copy(destinationRoot: directory.appendingPathComponent("Library"), eventName: "Collision"), buildPreviews: false)
        _ = try await importPhoto(file, into: Catalog(), options: options)
        // A valid JPEG permits trailing bytes: different content forces a unique destination.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let settings = edited()
        var history = DevelopHistory()
        history.record("Recovered collision", settings: settings, previous: .neutral)
        try XMPSidecar.write(XMPFields(), toSidecar: XMPSidecar.sidecarURL(for: file),
            develop: settings, filename: file.lastPathComponent, history: history)
        let catalog = try Catalog()
        let id = try await importPhoto(file, into: catalog, options: options)
        let copied = try XCTUnwrap(catalog.fileURL(for: id))
        XCTAssertNotEqual(copied.lastPathComponent, file.lastPathComponent)
        XCTAssertEqual(try catalog.developHistory(for: id).steps.map(\.name), ["Import", "Recovered collision"])
        XCTAssertEqual(try catalog.writeXMPSidecars().written, 1)
        let recovered = try Catalog()
        let restoredID = try await importPhoto(copied, into: recovered)
        XCTAssertEqual(try recovered.developHistory(for: restoredID), try catalog.developHistory(for: id))
    }

    private func recoveryXML(format: Int = 1, settings: String) -> String {
        let packet = DevelopRecovery.Packet(formatVersion: format, files: ["Photo.jpg": settings])
        let json = String(decoding: try! JSONEncoder().encode(packet), as: UTF8.self)
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:atelier="http://ns.atelier.app/xmp/1.0/"><atelier:DevelopRecovery>\(json)</atelier:DevelopRecovery></rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }
}
