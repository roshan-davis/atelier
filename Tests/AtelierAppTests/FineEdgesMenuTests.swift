import AtelierCore
import XCTest
@testable import AtelierApp

/// The Fine Edges model menu beside the checkbox (Rosh, Nov 16, 2026: with one model downloaded,
/// nothing in the panel said the other existed). SwiftUI fills the menu only when it opens on
/// screen, so its lines are checked here.
final class FineEdgesMenuTests: XCTestCase {
    func testOneModelDownloadedOffersTheOther() {
        let items = FineEdgesControl.menuItems(installed: [.hairDetail], active: .hairDetail, downloading: nil)
        XCTAssertEqual(items.map(\.title), ["Get Fast (115 MB)", "Hair Detail"])
        XCTAssertEqual(items.map(\.isGet), [true, false])
        XCTAssertEqual(items.map(\.isTicked), [false, true])
        XCTAssertEqual(items.map(\.isEnabled), [true, true])
    }

    func testTheFastModelOnlyOffersHairDetail() {
        let items = FineEdgesControl.menuItems(installed: [.fast], active: .fast, downloading: nil)
        XCTAssertEqual(items.map(\.title), ["Fast", "Get Hair Detail (470 MB)"])
        XCTAssertEqual(items.map(\.isTicked), [true, false])
    }

    func testBothDownloadedArePicksWithTheRunningOneTicked() {
        let items = FineEdgesControl.menuItems(installed: [.fast, .hairDetail], active: .hairDetail, downloading: nil)
        XCTAssertEqual(items.map(\.title), ["Fast", "Hair Detail"])
        XCTAssertEqual(items.map(\.isGet), [false, false])
        XCTAssertEqual(items.map(\.isTicked), [false, true])
    }

    func testGetIsDisabledWhileADownloadRuns() {
        let items = FineEdgesControl.menuItems(installed: [.hairDetail], active: .hairDetail, downloading: .fast)
        XCTAssertEqual(items.first?.title, "Get Fast (115 MB)")
        XCTAssertEqual(items.first?.isEnabled, false)
    }
}
