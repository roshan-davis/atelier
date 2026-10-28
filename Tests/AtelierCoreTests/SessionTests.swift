import XCTest
@testable import AtelierCore

final class SessionTests: XCTestCase {
    private func session(module: SavedSession.Module, focused: Int64?, selection: Set<Int64>) -> SavedSession {
        SavedSession(module: module, filter: LibraryFilter(scope: .importGroup(4), minRating: 3, flag: .picked,
                                                           colorLabel: .red, text: "eagle"),
                     selection: selection, focusedID: focused, zoom: .percent(200), gridTopID: 9)
    }

    func testRoundTripsThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionTests"))
        defaults.removePersistentDomain(forName: "SessionTests")
        let saved = session(module: .develop, focused: 7, selection: [7, 8])
        saved.save(to: defaults, key: "session")
        XCTAssertEqual(SavedSession.load(from: defaults, key: "session"), saved)

        // Grouping RAW+JPEG pairs is a setting, not part of the session.
        let filter = saved.filter(base: LibraryFilter(groupsRawPairs: false))
        XCTAssertEqual(filter, LibraryFilter(scope: .importGroup(4), minRating: 3, flag: .picked, colorLabel: .red,
                                             text: "eagle", groupsRawPairs: false))
        defaults.removePersistentDomain(forName: "SessionTests")
    }

    func testReopensDevelopOnTheSamePhoto() {
        let restored = session(module: .develop, focused: 7, selection: [7, 8])
            .restore(visibleIDs: [6, 7, 8]) { _ in true }
        XCTAssertEqual(restored, .init(module: .develop, selection: [7, 8], focusedID: 7))
    }

    func testOfflinePhotoFallsBackToGridButStaysSelected() {
        let restored = session(module: .develop, focused: 7, selection: [7])
            .restore(visibleIDs: [6, 7]) { _ in false }
        XCTAssertEqual(restored, .init(module: .grid, selection: [7], focusedID: 7))
    }

    func testRemovedPhotoFallsBackToGrid() {
        let restored = session(module: .loupe, focused: 7, selection: [7, 8])
            .restore(visibleIDs: [6, 8]) { _ in true }
        XCTAssertEqual(restored, .init(module: .grid, selection: [8], focusedID: nil))
    }

    func testDeletedImportFallsBackToAllPhotographs() {
        let sidebar = (volumes: [Int64(1)], folders: [Int64(2)], collections: [Int64(3)], imports: [Int64(5)])
        XCTAssertEqual(SavedSession.resolveScope(.importGroup(4), in: sidebar), .all)
        XCTAssertEqual(SavedSession.resolveScope(.importGroup(5), in: sidebar), .importGroup(5))
        XCTAssertEqual(SavedSession.resolveScope(.collection(3), in: sidebar), .collection(3))
    }

    func testHugeSelectionSavesOnlyTheFocusedPhoto() {
        let all = Set(Int64(1)...Int64(SavedSession.maxSavedSelection + 1))
        XCTAssertEqual(session(module: .grid, focused: 5, selection: all).selection, [5])
    }
}
