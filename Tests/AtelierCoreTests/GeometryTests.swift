import CoreImage
import XCTest
@testable import AtelierCore

final class GeometryTests: XCTestCase {
    typealias Crop = DevelopSettings.Crop

    private func image(width: CGFloat, height: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func testIdentityCropIsNotStored() throws {
        var settings = DevelopSettings()
        settings.crop = Crop()
        XCTAssertNil(settings.crop)
        XCTAssertTrue(settings.isNeutral)

        var crop = Crop()
        crop.x = 0.1
        crop.width = 0.5
        crop.angle = 3
        settings.crop = crop
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()).crop, crop)
    }

    func testCropTurnAndFlipSizes() {
        var crop = Crop()
        crop.x = 0.25
        crop.y = 0.5
        crop.width = 0.5
        crop.height = 0.5
        let cropped = DevelopRenderer.applyGeometry(crop, to: image(width: 400, height: 200))
        XCTAssertEqual(cropped.extent, CGRect(x: 0, y: 0, width: 200, height: 100))

        var turned = Crop()
        turned.quarterTurns = 1
        turned.flipHorizontal = true
        let output = DevelopRenderer.applyGeometry(turned, to: image(width: 400, height: 200))
        XCTAssertEqual(output.extent, CGRect(x: 0, y: 0, width: 200, height: 400))
        XCTAssertEqual(turned.outputSize(CGSize(width: 400, height: 200)), CGSize(width: 200, height: 400))
    }

    func testStraightenShrinksCropToFit() {
        var crop = Crop()
        crop.angle = 10
        XCTAssertFalse(crop.fits(imageAspect: 1.5), "a full-frame crop leaves corners off a rotated photo")
        let fitted = crop.fitted(imageAspect: 1.5)
        XCTAssertTrue(fitted.fits(imageAspect: 1.5))
        XCTAssertLessThan(fitted.width, 1)
        XCTAssertGreaterThan(fitted.width, 0.7)
        XCTAssertEqual(fitted.width / fitted.height, 1, accuracy: 0.001, "shrinking keeps the crop's shape")
        XCTAssertEqual(fitted.x + fitted.width / 2, 0.5, accuracy: 0.001)

        let rendered = DevelopRenderer.applyGeometry(fitted, to: image(width: 300, height: 200))
        XCTAssertEqual(Double(rendered.extent.width), fitted.width * 300, accuracy: 1.5)
        let uncropped = DevelopRenderer.applyGeometry(fitted, to: image(width: 300, height: 200), cropping: false)
        XCTAssertGreaterThan(uncropped.extent.width, 300, "the whole straightened photo is larger than its frame")
    }

    func testCenteredAspect() {
        let square = Crop.centered(aspect: 1, imageAspect: 1.5)
        XCTAssertEqual(square.width, 1 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(square.height, 1)
        let wide = Crop.centered(aspect: 16.0 / 9, imageAspect: 1.5)
        XCTAssertEqual(wide.width, 1)
        XCTAssertEqual(wide.height, 1.5 / (16.0 / 9), accuracy: 1e-9)
    }
}
