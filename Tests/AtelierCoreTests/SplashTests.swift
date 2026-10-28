import XCTest
@testable import AtelierCore

final class SplashTests: XCTestCase {
    func testEveryShapeFills() {
        guard case .fill(let crop) = Splash.layout(imageSize: CGSize(width: 3000, height: 2000)) else {
            return XCTFail("3:2 should fill")
        }
        // 3:2 into 16:10 keeps the full width and trims a little top and bottom, evenly.
        XCTAssertEqual(crop.width, 1, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 1.5 / 1.6, accuracy: 1e-9)
        XCTAssertEqual(crop.midY, 0.5, accuracy: 1e-9)
        // A portrait keeps its full width and a 16:10 band around the face.
        guard case .fill(let portrait) = Splash.layout(imageSize: CGSize(width: 2000, height: 3000),
                                                        focus: CGPoint(x: 0.5, y: 0.3)) else {
            return XCTFail("portraits fill too")
        }
        XCTAssertEqual(portrait.width, 1, accuracy: 1e-9)
        XCTAssertEqual(portrait.height, (2.0 / 3.0) / 1.6, accuracy: 1e-9)
        XCTAssertEqual(portrait.midY, 0.3, accuracy: 1e-9)
        XCTAssertEqual(Splash.layout(imageSize: .zero), .framed)
    }

    func testCropFollowsFocusButStaysInsideImage() {
        // A wide image with the subject on the right: the crop moves right but not past the edge.
        let crop = Splash.fillCrop(imageAspect: 1.9, focus: CGPoint(x: 0.95, y: 0.5))
        XCTAssertEqual(crop.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(crop.width, 1.6 / 1.9, accuracy: 1e-9)
        let top = Splash.fillCrop(imageAspect: 4.0 / 3.0, focus: CGPoint(x: 0.5, y: 0.2))
        XCTAssertEqual(top.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(top.width, 1, accuracy: 1e-9)
    }

    func testRotationGoesThroughEveryImageInNameOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        for name in ["b.jpg", "a.JPG", "c.heic", "notes.txt"] {
            try Data([0]).write(to: source.appendingPathComponent(name))
        }
        let builtIn = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        try Splash.installBuiltInImages(builtIn, into: folder)
        let images = Splash.images(in: folder)
        XCTAssertEqual(images.map(\.lastPathComponent), ["a.JPG", "b.jpg", "c.heic"])

        // Removed images stay removed: the folder is only filled the first time.
        try FileManager.default.removeItem(at: images[0])
        try Splash.installBuiltInImages(builtIn, into: folder)
        XCTAssertEqual(Splash.images(in: folder).count, 2)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let order = (0..<5).compactMap { _ in Splash.nextImage(from: images, defaults: defaults)?.lastPathComponent }
        XCTAssertEqual(order, ["a.JPG", "b.jpg", "c.heic", "a.JPG", "b.jpg"])
        XCTAssertNil(Splash.nextImage(from: [], defaults: defaults))
    }
}
