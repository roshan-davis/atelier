import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class AutoToneTests: XCTestCase {
    /// A dark, flat photo: Auto brightens it and stretches it toward white.
    func testBrightensADarkPhoto() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AtelierAuto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dark.jpg")
        try makeGradient(at: file, from: 0.04, to: 0.35)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 128))
        let auto = try XCTUnwrap(AutoTone.apply(session: session, settings: .neutral))
        XCTAssertGreaterThan(auto.exposure, 0.3)
        XCTAssertLessThanOrEqual(auto.blacks, 0, "Auto never lifts blacks")
        XCTAssertEqual(auto.contrast, 0, "Contrast is left alone")

        let only = try XCTUnwrap(AutoTone.apply(session: session, settings: .neutral, only: .whites))
        XCTAssertEqual(only.exposure, 0, "Shift-double-click sets just that slider")
    }

    private func makeGradient(at url: URL, from low: CGFloat, to high: CGFloat) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorSpace: space, colorComponents: [low, low, low, 1, high, high, high, 1],
                                                locations: [0, 1], count: 2))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 128, y: 0), options: [])
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
