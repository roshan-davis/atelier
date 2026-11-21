import CoreGraphics
import XCTest
@testable import AtelierCore

/// The one rule for what the Develop photo view shows (`SharpDisplay`).
final class SharpDisplayTests: XCTestCase {
    private let proxy = 2560.0, full = 6048.0
    /// Zoomed to 100% on the photo's top-left quarter.
    private let zoomed = DisplayNeed(visible: CGRect(x: 0, y: 0, width: 0.4, height: 0.4), density: 6048)
    private let visibleArea = CGRect(x: 0, y: 0, width: 0.4, height: 0.4)

    private func whole(_ photo: Int, _ revision: Int, _ width: Double) -> DisplayTag {
        DisplayTag(photo: photo, revision: revision, pixelWidth: width)
    }

    private func area(_ photo: Int, _ revision: Int, _ region: CGRect? = nil) -> DisplayTag {
        let region = region ?? visibleArea
        return DisplayTag(photo: photo, revision: revision, region: region, pixelWidth: full * region.width)
    }

    func testAtFitEverythingShowsAtOnce() {
        var rule = SharpDisplay()
        XCTAssertEqual(rule.offer(whole(1, -1, 1024), now: 0), .show(.base, clearsDetail: false))
        XCTAssertEqual(rule.offer(whole(1, 1, proxy), now: 0.1), .show(.base, clearsDetail: false))
        XCTAssertEqual(rule.offer(whole(2, -1, 1024), now: 0.2), .show(.base, clearsDetail: false))
    }

    func testZoomedPhotoChangeWaitsForTheSharpImage() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        XCTAssertEqual(rule.offer(whole(1, 3, full), now: 0), .show(.base, clearsDetail: false))
        // The next photo's stand-in and proxy wait; the old photo stays.
        XCTAssertEqual(rule.offer(whole(2, -1, proxy), now: 1), .wait(deadline: 1 + SharpDisplay.openWait))
        XCTAssertEqual(rule.offer(whole(2, 4, proxy), now: 1.1), .wait(deadline: 1 + SharpDisplay.openWait))
        XCTAssertEqual(rule.visible, whole(1, 3, full))
        // Its full-size image shows, and nothing soft ever did.
        XCTAssertEqual(rule.offer(whole(2, 4, full), now: 1.3), .show(.base, clearsDetail: false))
        XCTAssertNil(rule.pending)
        XCTAssertEqual(rule.expire(now: 2.5), .drop)
        // A late proxy of it changes nothing.
        XCTAssertEqual(rule.offer(whole(2, 4, proxy), now: 1.4).isShow, false)
    }

    func testAPhotoThatNeverSharpensShowsAfterItsWait() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        _ = rule.offer(whole(1, 3, full), now: 0)
        XCTAssertEqual(rule.offer(whole(2, 4, proxy), now: 1), .wait(deadline: 2))
        XCTAssertEqual(rule.expire(now: 1.5), .drop)
        XCTAssertEqual(rule.expire(now: 2), .show(.base, clearsDetail: false))
        XCTAssertEqual(rule.visible?.photo, 2)
    }

    func testZoomedDragShowsSharpFramesAndNeverTheProxy() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        _ = rule.offer(whole(1, 1, full), now: 0)
        var time = 0.0
        for revision in 2...60 {
            time += 1.0 / 60
            // The proxy frame of each tick waits; the visible-area frame of the tick shows.
            if case .show = rule.offer(whole(1, revision, proxy), now: time) { XCTFail("proxy shown at \(revision)") }
            XCTAssertEqual(rule.offer(area(1, revision), now: time + 0.03), .show(.detail, clearsDetail: false))
            XCTAssertEqual(rule.visible?.revision, revision)
            XCTAssertEqual(rule.expire(now: time + 0.03), .drop)
        }
        // At rest the settled proxy waits, the full-size image takes over from the area frame.
        XCTAssertEqual(rule.offer(whole(1, 60, proxy), now: 2).isShow, false)
        XCTAssertEqual(rule.offer(whole(1, 60, full), now: 2.1), .show(.base, clearsDetail: true))
        XCTAssertEqual(rule.visible, whole(1, 60, full))
    }

    func testNeverGoesBackToAnOlderEdit() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        _ = rule.offer(whole(1, 1, full), now: 0)
        _ = rule.offer(area(1, 5), now: 0.1)
        XCTAssertEqual(rule.offer(area(1, 4), now: 0.2), .drop)
        // An older full-size image goes under the newer area frame, unseen.
        XCTAssertEqual(rule.offer(whole(1, 3, full), now: 0.3), .show(.base, clearsDetail: false))
        XCTAssertEqual(rule.visible?.revision, 5)
    }

    func testSlowSharpFramesCostAtMostTheEditWait() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        _ = rule.offer(whole(1, 1, full), now: 0)
        XCTAssertEqual(rule.offer(whole(1, 2, proxy), now: 1), .wait(deadline: 1.25))
        // More soft frames keep the first deadline.
        XCTAssertEqual(rule.offer(whole(1, 3, proxy), now: 1.1), .wait(deadline: 1.25))
        XCTAssertEqual(rule.expire(now: 1.25), .show(.base, clearsDetail: false))
        XCTAssertEqual(rule.visible?.revision, 3)
        // Once soft is on screen, soft frames show at once until a sharp one comes.
        XCTAssertEqual(rule.offer(whole(1, 4, proxy), now: 1.3), .show(.base, clearsDetail: false))
        XCTAssertEqual(rule.offer(area(1, 5), now: 1.33), .show(.detail, clearsDetail: false))
    }

    func testPanningOffTheAreaFrameDropsIt() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        _ = rule.offer(whole(1, 1, full), now: 0)
        _ = rule.offer(area(1, 2), now: 0.1)
        XCTAssertFalse(rule.setNeed(DisplayNeed(visible: CGRect(x: 0.05, y: 0.05, width: 0.3, height: 0.3), density: 6048)))
        XCTAssertTrue(rule.setNeed(DisplayNeed(visible: CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), density: 6048)))
        XCTAssertNil(rule.detail)
        XCTAssertEqual(rule.visible, whole(1, 1, full))
    }

    func testAnAreaFrameOfAnotherPhotoIsDropped() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        _ = rule.offer(whole(1, 1, full), now: 0)
        XCTAssertEqual(rule.offer(area(2, 2), now: 0.1), .drop)
        XCTAssertEqual(rule.visible?.photo, 1)
    }

    func testTheSameImageAgainChangesNothing() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        XCTAssertEqual(rule.offer(whole(1, 1, full), now: 0), .show(.base, clearsDetail: false))
        XCTAssertEqual(rule.offer(whole(1, 1, full), now: 0.1), .drop)
        XCTAssertEqual(rule.offer(area(1, 2), now: 0.2), .show(.detail, clearsDetail: false))
        XCTAssertEqual(rule.offer(area(1, 2), now: 0.3), .drop)
        XCTAssertEqual(rule.visible, area(1, 2))
    }

    func testASharpAreaOfTheNextPhotoShowsOverItsWaitingImage() {
        var rule = SharpDisplay()
        _ = rule.setNeed(zoomed)
        _ = rule.offer(whole(1, 3, full), now: 0)
        XCTAssertEqual(rule.offer(whole(2, 4, proxy), now: 1), .wait(deadline: 2))
        XCTAssertEqual(rule.offer(area(2, 4), now: 1.1), .showOverHeld)
        XCTAssertEqual(rule.visible, area(2, 4))
        XCTAssertEqual(rule.base, whole(2, 4, proxy))
        XCTAssertNil(rule.pending)
        // Its full-size image takes over; the old photo never comes back.
        XCTAssertEqual(rule.offer(whole(2, 4, full), now: 1.4), .show(.base, clearsDetail: true))
        XCTAssertEqual(rule.offer(whole(1, 5, full), now: 1.5), .drop)
    }

    func testAtFitTheSettledProxyAfterAFrameOfTheSameEditChangesNothing() {
        var rule = SharpDisplay()
        XCTAssertEqual(rule.offer(whole(1, 7, proxy), now: 0), .show(.base, clearsDetail: false))
        // The settled render of the same edit, as an ordinary image: as sharp, so it may replace it.
        XCTAssertEqual(rule.offer(whole(1, 7, proxy + 0.5), now: 0.2), .show(.base, clearsDetail: false))
        XCTAssertEqual(rule.offer(whole(1, 7, 1024), now: 0.3), .drop)
    }
}

private extension SharpDisplay.Decision {
    var isShow: Bool { if case .show = self { return true } else { return false } }
}
