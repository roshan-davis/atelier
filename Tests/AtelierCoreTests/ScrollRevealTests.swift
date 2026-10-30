import XCTest
@testable import AtelierCore

final class ScrollRevealTests: XCTestCase {
    func testVisibleItemDoesNotScroll() {
        XCTAssertNil(ScrollReveal.offset(item: 120...260, visibleStart: 100, visibleLength: 400, contentLength: 2000))
        // Exactly at the edges still counts as visible.
        XCTAssertNil(ScrollReveal.offset(item: 100...500, visibleStart: 100, visibleLength: 400, contentLength: 2000))
    }

    func testItemBelowComesUpToTheBottomEdge() {
        // Just the amount needed: the item's end lands on the view's end, plus the margin.
        XCTAssertEqual(ScrollReveal.offset(item: 450...600, visibleStart: 100, visibleLength: 400,
                                           contentLength: 2000, margin: 10), 210)
    }

    func testItemAboveGoesDownToTheTopEdge() {
        XCTAssertEqual(ScrollReveal.offset(item: 40...180, visibleStart: 100, visibleLength: 400,
                                           contentLength: 2000, margin: 10), 30)
    }

    func testOffsetStaysWithinTheContent() {
        XCTAssertEqual(ScrollReveal.offset(item: 0...50, visibleStart: 100, visibleLength: 400,
                                           contentLength: 2000, margin: 16), 0)
        XCTAssertEqual(ScrollReveal.offset(item: 1900...2000, visibleStart: 100, visibleLength: 400,
                                           contentLength: 2000, margin: 16), 1600)
    }

    func testItemTallerThanTheViewShowsItsStart() {
        XCTAssertEqual(ScrollReveal.offset(item: 600...1200, visibleStart: 100, visibleLength: 400,
                                           contentLength: 2000), 600)
    }
}
