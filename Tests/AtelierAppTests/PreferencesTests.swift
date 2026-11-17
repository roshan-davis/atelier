import Foundation
import XCTest
@testable import AtelierApp

/// AT-076 E2: settings read in more than one place have one key and one default.
final class PreferencesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testAValueOrItsDefault() throws {
        let suite = "PreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(defaults.value(Preferences.clickZoomPercent), 100, "nothing stored: the default")
        defaults.set(200.0, for: Preferences.clickZoomPercent)
        XCTAssertEqual(defaults.value(Preferences.clickZoomPercent), 200)
        defaults.set("not a size", forKey: Preferences.aiGenerationSize.key)
        XCTAssertEqual(defaults.value(Preferences.aiGenerationSize), 1024, "another type: the default")
        XCTAssertTrue(defaults.value(Preferences.exportReveals))
    }

    /// Outside `Preferences.swift` these keys are only reached through their `Preference`, so a
    /// reader can't pick another default. (The layout snapshots set some directly; they stay as
    /// they are until their hooks move, AT-076 B2.)
    func testSharedKeysAreOnlyWrittenOnce() throws {
        let keys = [Preferences.xmpAutoWrite.key, Preferences.backupsToKeep.key, Preferences.clickZoomPercent.key,
                    Preferences.showClipping.key, Preferences.soloMode.key, Preferences.expandedPanels.key,
                    Preferences.importCopies.key, Preferences.importDestination.key, Preferences.exportDestination.key,
                    Preferences.exportReveals.key, Preferences.aiServer.key, Preferences.aiEditModel.key,
                    Preferences.aiUpscaleModel.key, Preferences.aiGenerationSize.key, Preferences.aiUpscaleFactor.key]
        let sources = Self.root.appendingPathComponent("Sources/AtelierApp")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !["Preferences.swift", "LayoutSnapshots.swift"].contains($0.lastPathComponent) } ?? []
        XCTAssertFalse(files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for key in keys where text.contains("\"\(key)\"") { offenders.append("\(file.lastPathComponent): \(key)") }
        }
        XCTAssertEqual(offenders, [], "use the key's Preference (Preferences.swift)")
    }
}
