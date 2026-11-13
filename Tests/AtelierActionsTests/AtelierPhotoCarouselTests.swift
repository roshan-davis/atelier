import AgentActions
import AgentMCP
@testable import AtelierActions
import Foundation
import XCTest

final class AtelierPhotoCarouselTests: XCTestCase {
    func testViewIsAnMCPAppWithNoOutsideConnections() {
        let resource = AtelierPhotoCarousel.resource
        XCTAssertEqual(resource.uri, "ui://atelier/photos")
        XCTAssertEqual(resource.mimeType, MCPApps.mimeType)
        XCTAssertTrue(resource.isView)
        let html = resource.text
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        for message in ["ui/initialize", "ui/notifications/initialized", "ui/notifications/tool-result",
                        "ui/notifications/size-changed", "get_thumbnails", "\"show\"", "ui/message"] {
            XCTAssertTrue(html.contains(message), message)
        }
        // Nothing is fetched from outside: no URLs to load and no network calls.
        for outside in ["http://", "https://", "<link", "src=\"", "fetch(", "XMLHttpRequest", "innerHTML"] {
            XCTAssertFalse(html.contains(outside), outside)
        }
    }

    func testThumbnailsAreOnlyForTheView() {
        let tool = AtelierPhotoCarousel.getThumbnails
        XCTAssertTrue(tool.isAppOnly)
        XCTAssertTrue(tool.readOnly)
        XCTAssertEqual(tool.json(apps: true)["_meta"]?["ui"]?["visibility"], .array([.string("app")]))
        XCTAssertNil(AtelierPhotoCarousel.link.visibility.first(where: { $0 != .model && $0 != .app }))
        XCTAssertFalse(MCPTool(name: "search_photos", title: "", description: "", readOnly: true,
                               ui: AtelierPhotoCarousel.link).isAppOnly)
    }

    func testThumbnailIDsAreChecked() {
        func ids(_ text: String) -> Result<[Int64], ParameterCheck.Problems> {
            AtelierPhotoCarousel.thumbnailIDs(JSONValue(parsing: Data(text.utf8))?.objectValue ?? [:])
        }
        XCTAssertEqual(try ids(#"{"ids":[3,1,3]}"#).get(), [3, 1])
        XCTAssertThrowsError(try ids(#"{}"#).get())
        XCTAssertThrowsError(try ids(#"{"ids":["a"]}"#).get())
        let many = (1...25).map(String.init).joined(separator: ",")
        XCTAssertThrowsError(try ids("{\"ids\":[\(many)]}").get())
    }
}
