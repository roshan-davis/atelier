import AppKit
import XCTest
@testable import AtelierApp

final class CatalogLaunchTests: XCTestCase {
    @MainActor
    func testFailedLaunchDoesNotInstallLibraryOrMakeQuitBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Library.atelier")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let database = package.appendingPathComponent("catalog.sqlite")
        let damaged = Data("damaged database".utf8)
        try damaged.write(to: database)
        let launch = CatalogLaunch(packageURL: package)
        launch.open()
        await launch.task?.value
        XCTAssertNil(launch.model, "LibraryCommands and Settings receive no library on failure")
        XCTAssertNotNil(launch.opening.failureReason)
        let delegate = AppDelegate()
        delegate.model = launch.model
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("Backups").path))
        XCTAssertEqual(try Data(contentsOf: database), damaged)
        launch.open()
        await launch.task?.value
        XCTAssertNil(launch.model)
        XCTAssertEqual(try Data(contentsOf: database), damaged)
    }
}
