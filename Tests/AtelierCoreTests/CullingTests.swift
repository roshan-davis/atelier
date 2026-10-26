import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

final class CullingTests: XCTestCase {
    func testGroupsByTimeAndLooks() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        // A burst (0, 0.3 s, 0.6 s), a re-take 5 s later that looks alike, then a new scene,
        // then a shot two minutes later that happens to look like the first.
        let times: [Date?] = [start, start + 0.3, start + 0.6, start + 5.6, start + 9, start + 130]
        let looks: [Int] = [0, 0, 0, 0, 1, 0]
        let groups = Culling.groups(count: times.count, times: { times[$0] },
                                    distance: { looks[$0] == looks[$1] ? 0.2 : 1.2 }, threshold: 0.5)
        XCTAssertEqual(groups, [[0, 1, 2, 3], [4], [5]])
    }

    func testLooserThresholdJoinsMore() {
        let start = Date(timeIntervalSince1970: 0)
        let times: [Date?] = [start, start + 4, start + 8]
        let tight = Culling.groups(count: 3, times: { times[$0] }, distance: { _, _ in 0.6 }, threshold: 0.4)
        let loose = Culling.groups(count: 3, times: { times[$0] }, distance: { _, _ in 0.6 }, threshold: 0.8)
        XCTAssertEqual(tight.count, 3)
        XCTAssertEqual(loose, [[0, 1, 2]])
    }

    func testSuggestsTheSharpestAndBestFace() {
        let blurry = CullSignals(sharpness: 40), sharp = CullSignals(sharpness: 400)
        XCTAssertEqual(Culling.suggestedKeeper([blurry, sharp, blurry]), 1)
        // A slightly softer photo with eyes open beats a sharp one with eyes closed.
        let sharpClosed = CullSignals(sharpness: 400, faceQuality: 0.1)
        let softOpen = CullSignals(sharpness: 340, faceQuality: 0.8)
        XCTAssertEqual(Culling.suggestedKeeper([sharpClosed, softOpen]), 1)
    }

    func testSharpnessDropsWithBlur() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AtelierCull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sharpURL = dir.appendingPathComponent("sharp.png"), softURL = dir.appendingPathComponent("soft.png")
        try writeCheckerboard(to: sharpURL, blur: false)
        try writeCheckerboard(to: softURL, blur: true)
        let sharp = Culling.analyze(sharpURL), soft = Culling.analyze(softURL)
        XCTAssertGreaterThan(sharp.sharpness, soft.sharpness * 2)
        XCTAssertNotNil(sharp.thumbnail)
        if let distance = Culling.distance(sharp, soft) {
            print("feature print distance sharp/soft: \(distance)")
        }
    }

    private func writeCheckerboard(to url: URL, blur: Bool) throws {
        let size = 600
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 0, to: size, by: 20) {
            for x in stride(from: (y / 20) % 2 * 20, to: size, by: 40) {
                context.fill(CGRect(x: x, y: y, width: 20, height: 20))
            }
        }
        var image = try XCTUnwrap(context.makeImage())
        if blur {
            // Down and back up: a soft copy of the same scene.
            let small = try XCTUnwrap(CGContext(data: nil, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            small.interpolationQuality = .high
            small.draw(image, in: CGRect(x: 0, y: 0, width: 60, height: 60))
            context.interpolationQuality = .high
            context.draw(try XCTUnwrap(small.makeImage()), in: CGRect(x: 0, y: 0, width: size, height: size))
            image = try XCTUnwrap(context.makeImage())
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
