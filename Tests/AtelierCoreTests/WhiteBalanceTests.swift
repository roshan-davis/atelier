import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class WhiteBalanceTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierWB-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testPresetsMatchLightroom() {
        XCTAssertEqual(WhiteBalance.presets.map(\.name), ["Daylight", "Cloudy", "Shade", "Tungsten", "Fluorescent", "Flash"])
        XCTAssertEqual(WhiteBalance.presets.first { $0.name == "Tungsten" }?.temperature, 2850)
    }

    /// A warm gray card with a saturated red beside it: the selector on the card makes the card
    /// neutral even though the red would pull an average the other way.
    func testSelectorMakesTheClickedSpotNeutral() throws {
        let file = workDir.appendingPathComponent("card.jpg")
        try makeJPEG(at: file, left: [0.62, 0.55, 0.42], right: [0.8, 0.1, 0.1])
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 128))
        let before = try color(session, .neutral, x: 0.25)
        XCTAssertGreaterThan(before.0 - before.2, 0.1, "the card starts warm: \(before)")

        let found = try XCTUnwrap(WhiteBalance.neutral(session: session, settings: .neutral,
                                                       area: CGRect(x: 0.24, y: 0.49, width: 0.02, height: 0.02)))
        var settings = DevelopSettings()
        settings.temperature = found.temperature
        settings.tint = found.tint
        let after = try color(session, settings, x: 0.25)
        XCTAssertEqual(after.0, after.2, accuracy: 0.03, "red and blue match on the card: \(after)")
        XCTAssertEqual(after.0, after.1, accuracy: 0.03, "red and green match on the card: \(after)")
    }

    func testAutoNeutralizesAColorCast() throws {
        let file = workDir.appendingPathComponent("cast.jpg")
        try makeJPEG(at: file, left: [0.45, 0.5, 0.7], right: [0.3, 0.33, 0.5])
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 128))
        let found = try XCTUnwrap(WhiteBalance.neutral(session: session, settings: .neutral))
        var settings = DevelopSettings()
        settings.temperature = found.temperature
        settings.tint = found.tint
        let before = try color(session, .neutral, x: 0.25)
        let after = try color(session, settings, x: 0.25)
        XCTAssertLessThan(abs(after.2 - after.0), abs(before.2 - before.0) * 0.4, "before \(before), after \(after)")
    }

    // MARK: Helpers

    private func color(_ session: DevelopSession, _ settings: DevelopSettings, x: Double) throws -> (Double, Double, Double) {
        let pixels = try XCTUnwrap(WhiteBalance.sample(session, settings))
        let px = Int(Double(pixels.width) * x), py = pixels.height / 2
        let i = (py * pixels.width + px) * 4
        return (Double(pixels.data[i]) / 255, Double(pixels.data[i + 1]) / 255, Double(pixels.data[i + 2]) / 255)
    }

    private func makeJPEG(at url: URL, left: [CGFloat], right: [CGFloat]) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: left + [1])!)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(colorSpace: space, components: right + [1])!)
        context.fill(CGRect(x: 64, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
