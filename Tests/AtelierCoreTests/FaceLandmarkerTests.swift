import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AtelierCore

/// The built-in MediaPipe Face Landmarker behind Cull's blinks and smiles: its crop, and the
/// models themselves on a real portrait.
final class FaceLandmarkerTests: XCTestCase {
    private func image(width: Int, height: Int, gray: UInt8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let v = CGFloat(gray) / 255
        context.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// The crop is 1.5 times the face, so a face at the photo's left edge leaves black where the
    /// crop runs past it, as Google's pipeline does.
    func testCropPadsOutsideThePhotoWithBlack() throws {
        let photo = try image(width: 400, height: 300, gray: 204)
        // A 100 px face against the left edge, halfway down: the crop is 150 px, 25 px past the edge.
        let box = CGRect(x: 0, y: 1 - 200.0 / 300, width: 100.0 / 400, height: 100.0 / 300)
        let crop = try XCTUnwrap(FaceLandmarker.crop(photo, box: box))
        let size = FaceLandmarker.size
        XCTAssertEqual(crop.count, size * size * 3)
        func value(_ x: Int, _ y: Int) -> Float { crop[(y * size + x) * 3] }
        XCTAssertEqual(value(5, size / 2), 0, accuracy: 0.01, "left of the photo")
        XCTAssertEqual(value(size / 2, size / 2), 0.8, accuracy: 0.02, "the face")
        XCTAssertEqual(value(size - 3, 3), 0.8, accuracy: 0.02)
    }

    /// The models ship inside AtelierCore's resources and read the smiling woman in a Help
    /// portrait as Google's own TFLite runtime does (blink 0.14 / 0.09, smile 0.92 / 0.91, on
    /// the face box OpenCV finds: 94 px at 112, 58 of the 312 × 390 picture).
    func testBuiltInModelsOnAPortrait() throws {
        XCTAssertNotNil(FaceLandmarker.mesh.packageURL(), "FaceMesh.mlpackage is missing from AtelierCore's resources")
        XCTAssertNotNil(FaceLandmarker.blendshapes.packageURL(), "FaceBlendshapes.mlpackage is missing")
        XCTAssertTrue(FaceLandmarker.isAvailable, "the face landmarker doesn't load")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/AtelierApp/Help/images/look-before-portrait.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let photo = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let box = CGRect(x: 112.0 / 312, y: 1 - (58.0 + 94) / 390, width: 94.0 / 312, height: 94.0 / 390)
        let face = try XCTUnwrap(FaceLandmarker.expression(in: photo, box: box), "no face found in the box")
        XCTAssertLessThan(face.blink, 0.3, "eyes open")
        XCTAssertGreaterThan(face.smile, 0.7, "smiling")
        // No face in a plain gray picture: the mesh model says so.
        XCTAssertNil(FaceLandmarker.expression(in: try image(width: 300, height: 300, gray: 128),
                                               box: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)))
    }
}
