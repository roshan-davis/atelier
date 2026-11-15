import CoreImage
import Foundation
import XCTest
@testable import AtelierCore

/// Depth Range masks (AT-068): the range, picking on the photo, the depth model's input and
/// output, and the mask kernel.
final class DepthRangeTests: XCTestCase {
    private typealias Component = DevelopSettings.MaskComponent

    func testDepthRangeSavesAndOldCatalogsAreUnchanged() throws {
        let component = Component(.depth(DevelopSettings.DepthRange(low: 40, high: 80, smoothness: 20)))
        XCTAssertEqual(component.kind, .depth)
        XCTAssertEqual(component.kind.title, "Depth Range")
        XCTAssertNil(component.pin)
        XCTAssertFalse(Component.Kind.depth.isDrawn, "made at once, then picked on the photo")
        var settings = DevelopSettings()
        settings.masks = [DevelopSettings.Mask(name: "Mask 1", components: [component])]
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        let bare = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","components":[{"kind":"depth"}]}]}"#)
        XCTAssertEqual(bare.masks.first?.components.first?.shape, .depth(DevelopSettings.DepthRange()))
    }

    func testWeightIsLuminanceRangesSoftEdge() {
        let range = DevelopSettings.DepthRange(low: 20, high: 40, smoothness: 50)
        XCTAssertEqual(range.weight(at: 0.3), 1)
        XCTAssertEqual(range.weight(at: 0.9), 0)
        let luminance = DevelopSettings.LuminanceRange(low: 20, high: 40, smoothness: 50)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(range.weight(at: x), luminance.weight(at: x))
        }
    }

    func testPickingAClickAnAreaAndWidening() throws {
        let range = DevelopSettings.DepthRange()
        let click = try XCTUnwrap(range.picking([0.5], area: false, adding: false))
        XCTAssertEqual(click.low, 42)
        XCTAssertEqual(click.high, 58)
        let area = (0..<100).map { Float($0) / 100 * 0.4 + 0.5 }
        let dragged = try XCTUnwrap(range.picking(area, area: true, adding: false))
        XCTAssertEqual(dragged.low, 52)
        XCTAssertEqual(dragged.high, 88)
        let widened = try XCTUnwrap(click.picking([0.9], area: false, adding: true))
        XCTAssertEqual(widened.low, 42, "⇧ keeps the near end")
        XCTAssertEqual(widened.high, 98)
        XCTAssertNil(range.picking([], area: false, adding: false))
        let edge = try XCTUnwrap(range.picking([0.01], area: false, adding: false))
        XCTAssertEqual(edge.low, 0, "kept on 0...100")
    }

    func testModelInputKeepsTheShapeInMultiplesOf14() {
        let landscape = DepthMap.inputSize(width: 6000, height: 4000)
        XCTAssertEqual(landscape.height, 518)
        XCTAssertEqual(landscape.width % 14, 0)
        XCTAssertEqual(Double(landscape.width), 777, accuracy: 7)
        let portrait = DepthMap.inputSize(width: 400, height: 1200)
        XCTAssertEqual(portrait.width, 518)
        XCTAssertEqual(portrait.height, 1036, "at most twice as long")
        XCTAssertEqual(DepthMap.inputSize(width: 100, height: 100).width, 518)
    }

    func testOutputBecomesNearZeroFarOne() {
        // The model gives higher numbers for nearer things.
        let raw: [Float] = (0..<200).map { Float($0) }
        let depth = DepthMap.normalized(raw)
        XCTAssertEqual(depth.last ?? -1, 0, accuracy: 1e-6, "the nearest is 0")
        XCTAssertEqual(depth.first ?? -1, 1, accuracy: 1e-6, "the farthest is 1")
        XCTAssertGreaterThan(depth[50], depth[150])
        XCTAssertEqual(DepthMap.normalized([3, 3, 3]).count, 3)
    }

    func testFieldReadsBoxes() {
        let field = DepthMap.Field(width: 4, height: 2, values: [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7])
        XCTAssertEqual(field.value(atX: 0.9, y: 0.9), 0.7)
        XCTAssertEqual(field.values(in: DevelopSettings.MaskRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)), [0.6, 0.7])
        XCTAssertEqual(field.values(in: DevelopSettings.MaskRect(x: 0.1, y: 0.1, width: 0, height: 0)), [0])
    }

    func testMaskKernelKeepsTheRange() throws {
        try XCTSkipUnless(DevelopRenderer.depthRangeKernelAvailable, "The Depth Range kernel didn't build here")
        // Left half near (0.1), right half far (0.9), as the depth map gives it.
        let field = DepthMap.Field(width: 2, height: 1, values: [0.1, 0.9])
        let extent = CGRect(x: 0, y: 0, width: 32, height: 16)
        let map = try XCTUnwrap(field.image(on: extent))
        let mask = try XCTUnwrap(DevelopRenderer.depthRangeMask(DevelopSettings.DepthRange(low: 0, high: 30, smoothness: 0),
                                                                from: map))
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func read(x: Int) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(mask, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: 8, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
            return pixel[0]
        }
        XCTAssertEqual(read(x: 2), 1, accuracy: 0.01, "near is in the mask")
        XCTAssertEqual(read(x: 29), 0, accuracy: 0.01, "far is not")
    }
}
