@testable import AtelierCore
import XCTest

final class DockLayoutTests: XCTestCase {
    func testLeftPanelGoesFirstThenTheRight() {
        // 240-point sidebar, 320-point inspector: both fit from 1040 points.
        XCTAssertEqual(DockLayout.fitting(width: 1200, sidebar: 240, inspector: 320), .full)
        XCTAssertEqual(DockLayout.fitting(width: 1040, sidebar: 240, inspector: 320), .full)
        XCTAssertEqual(DockLayout.fitting(width: 900, sidebar: 240, inspector: 320),
                       DockLayout(showsSidebar: false, showsInspector: true))
        XCTAssertEqual(DockLayout.fitting(width: 700, sidebar: 240, inspector: 320),
                       DockLayout(showsSidebar: false, showsInspector: false))
        XCTAssertEqual(DockLayout.fitting(width: DockLayout.minimumWidth, sidebar: 240, inspector: 320),
                       DockLayout(showsSidebar: false, showsInspector: false))
    }

    func testAHiddenInspectorLeavesRoomForTheSidebar() {
        XCTAssertEqual(DockLayout.fitting(width: 760, sidebar: 240, inspector: 0), .full)
        XCTAssertEqual(DockLayout.fitting(width: 700, sidebar: 240, inspector: 0),
                       DockLayout(showsSidebar: false, showsInspector: true))
    }

    func testThePhotoAloneFitsTheMinimum() {
        XCTAssertGreaterThanOrEqual(DockLayout.minimumWidth, DockLayout.photoMinimum)
    }
}
