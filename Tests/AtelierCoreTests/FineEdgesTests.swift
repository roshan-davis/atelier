import CoreImage
import Foundation
import XCTest
@testable import AtelierCore

final class FineEdgesTests: XCTestCase {
    func testInputIsNormalizedRGBPlanes() {
        let size = FineEdges.Model.fast.size
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels[0] = 255; pixels[1] = 128; pixels[2] = 0
        let input = FineEdges.inputTensor(pixels, size: size)
        XCTAssertEqual(input.count, size * size * 3)
        XCTAssertEqual(input[0], (1 - 0.485) / 0.229, accuracy: 1e-5)
        XCTAssertEqual(input[size * size], (128.0 / 255 - 0.456) / 0.224, accuracy: 1e-5)
        XCTAssertEqual(input[2 * size * size], (0 - 0.406) / 0.225, accuracy: 1e-5)
    }

    func testLogitsBecomeChancesAndChancesStay() {
        let logits = FineEdges.probabilities([-10, 0, 10])
        XCTAssertEqual(logits[0], 0, accuracy: 1e-4)
        XCTAssertEqual(logits[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(logits[2], 1, accuracy: 1e-4)
        XCTAssertEqual(FineEdges.probabilities([0, 0.25, 1]), [0, 0.25, 1])
    }

    func testChecksumIsSHA256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try FineEdges.checksum(of: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testOldSelectionsHaveFineEdgesOff() throws {
        let subject = try JSONDecoder().decode(DevelopSettings.Selection.self, from: Data(#"{"feather":20}"#.utf8))
        XCTAssertFalse(subject.fineEdges)
        let people = try JSONDecoder().decode(DevelopSettings.PeopleSelection.self, from: Data(#"{"feather":10}"#.utf8))
        XCTAssertFalse(people.fineEdges)
    }

    /// A square selection, a matte reaching further right (strands Vision missed) and missing a
    /// notch at the top edge (background between them): the edge follows the matte near the
    /// selection, the middle stays, and nothing far away is added.
    func testFineEdgesFollowTheMatteOnlyNearTheEdge() throws {
        let extent = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let black = CIImage(color: .black).cropped(to: extent)
        func box(_ rect: CGRect) -> CIImage { CIImage(color: .white).cropped(to: rect).composited(over: black) }
        let mask = box(CGRect(x: 300, y: 300, width: 400, height: 400))
        // Matte: the box widened 5 px to the right, plus a far-away blob, less a notch at the top.
        let matte = CIImage(color: .black).cropped(to: CGRect(x: 480, y: 696, width: 40, height: 4))
            .composited(over: box(CGRect(x: 300, y: 300, width: 405, height: 400)))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 900, y: 900, width: 50, height: 50)))
        let result = DevelopRenderer.fineEdged(mask, outline: mask, matte: matte, extent: extent)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func value(_ x: Int, _ y: Int) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(result, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
            return pixel[0]
        }
        XCTAssertEqual(value(500, 500), 255, "the middle stays")
        XCTAssertEqual(value(702, 500), 255, "a strand next to the edge is added")
        XCTAssertEqual(value(500, 698), 0, "background inside the edge band drops out")
        XCTAssertEqual(value(920, 920), 0, "foreground far from the selection isn't added")
    }
}

final class MaskGuidedFilterTests: XCTestCase {
    /// A mask whose edge sits 6 px left of the photo's edge: refined, it moves onto the photo's
    /// edge, and it is never emptied (Refine Edge above 0 used to remove the selection).
    func testRefineEdgeMovesTheEdgeOntoThePhotosEdge() throws {
        try XCTSkipUnless(MaskGuidedFilter.kernelsAvailable, "Metal kernels unavailable")
        let extent = CGRect(x: 0, y: 0, width: 400, height: 200)
        func halves(_ x: CGFloat, _ left: CIColor, _ right: CIColor) -> CIImage {
            CIImage(color: left).cropped(to: CGRect(x: 0, y: 0, width: x, height: 200))
                .composited(over: CIImage(color: right).cropped(to: extent))
        }
        let photo = halves(200, CIColor(red: 0.8, green: 0.8, blue: 0.8), CIColor(red: 0.02, green: 0.02, blue: 0.02))
        let mask = halves(194, .white, .black)
        let refined = try XCTUnwrap(MaskGuidedFilter.apply(mask: mask, guide: photo, radius: 12, epsilon: 0.0001,
                                                           extent: extent))
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func value(_ x: Int) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(refined, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: 100, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
            return pixel[0]
        }
        XCTAssertGreaterThan(value(100), 0.95, "the selection stays")
        XCTAssertGreaterThan(value(197), 0.4, "the edge moved out toward the photo's edge (was 0)")
        XCTAssertLessThan(value(205), 0.3, "and stops there")
        XCTAssertLessThan(value(300), 0.05)
    }
}
