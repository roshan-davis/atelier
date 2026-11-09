import AppKit
import XCTest
@testable import AtelierApp

final class ZoomScrollViewTests: XCTestCase {
    @MainActor
    func testPinchEndReportsMagnificationEvenIfLayoutAlreadyReportedIt() async throws {
        let view = ZoomScrollView()
        view.setFrameSize(NSSize(width: 500, height: 300))
        view.setImage(NSImage(size: NSSize(width: 3000, height: 2000)), pixelSize: nil)

        var sharedLevel: ZoomLevel = .fit
        view.onZoomChange = { sharedLevel = $0 }
        var layoutReport: ZoomReport?
        let layoutReported = expectation(description: "Layout reported before the pinch committed")
        view.onReport = {
            layoutReport = $0
            layoutReported.fulfill()
        }
        view.apply(.percent(100))
        await fulfillment(of: [layoutReported], timeout: 2)
        XCTAssertEqual(sharedLevel, .fit)
        let previousReport = try XCTUnwrap(layoutReport)
        XCTAssertTrue(previousReport.isZoomedPastFit)

        let pinchReported = expectation(description: "The committed pinch reports the same magnification")
        view.onReport = {
            XCTAssertEqual(sharedLevel, .percent(100))
            XCTAssertEqual($0, previousReport)
            pinchReported.fulfill()
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: view)
        await fulfillment(of: [pinchReported], timeout: 2)
    }
}
