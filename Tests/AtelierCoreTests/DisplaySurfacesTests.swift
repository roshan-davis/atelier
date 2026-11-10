import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// Live Develop frames drawn into a GPU surface must show exactly what the ordinary render
/// (`renderForDisplay`) shows: same way up, same colors.
final class DisplaySurfacesTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierSurfaces-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testSurfaceFrameMatchesOrdinaryRender() throws {
        let file = workDir.appendingPathComponent("halves.png")
        try makeHalves(at: file, width: 60, height: 40)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: 60))
        var settings = DevelopSettings()
        settings.contrast = 30
        settings[.saturation] = 20
        for clipping in [false, true] {
            let ordinary = try XCTUnwrap(session.renderForDisplay(settings, shadowClipping: clipping,
                                                                  highlightClipping: clipping)).image
            let surfaces = DisplaySurfaces()
            let frame = try XCTUnwrap(session.renderToSurface(settings, shadowClipping: clipping,
                                                              highlightClipping: clipping, surfaces: surfaces))
            XCTAssertEqual(frame.surface.width, ordinary.width)
            XCTAssertEqual(frame.surface.height, ordinary.height)
            XCTAssertNotNil(frame.plain)
            let expected = try rgba(ordinary)
            for (x, y) in [(5, 5), (30, 8), (55, 35), (10, 30), (30, 20)] {
                let want = expected(x, y)
                let got = try surfacePixel(frame.surface, x: x, y: y)
                for channel in 0..<3 {
                    XCTAssertEqual(Int(got[channel]), Int(want[channel]), accuracy: 1,
                                   "pixel (\(x), \(y)) channel \(channel), clipping \(clipping)")
                }
            }
            surfaces.checkIn(frame.surface)
        }
    }

    func testPoolNeverHandsOutMoreThanItsLimit() {
        let surfaces = DisplaySurfaces()
        var out: [IOSurface] = []
        for _ in 0..<DisplaySurfaces.limit {
            guard let surface = surfaces.checkOut(width: 8, height: 8) else { return XCTFail("pool ran out early") }
            out.append(surface)
        }
        var full = 0
        XCTAssertNil(surfaces.checkOut(width: 8, height: 8, onPoolFull: { full += 1 }))
        XCTAssertEqual(full, 1)
        surfaces.checkIn(out[0])
        XCTAssertTrue(surfaces.checkOut(width: 8, height: 8, onPoolFull: { full += 1 }) === out[0])
        XCTAssertEqual(full, 1)
        // A new size starts a new set; old ones coming back are let go.
        XCTAssertNotNil(surfaces.checkOut(width: 16, height: 8))
        surfaces.checkIn(out[1])
        XCTAssertNotNil(surfaces.checkOut(width: 16, height: 8))
    }

    // MARK: Helpers

    /// Top half orange, bottom half blue, so a frame upside down or with red and blue swapped fails.
    private func makeHalves(at url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // CGContext's y axis points up: the top half is y >= height / 2.
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        context.setFillColor(CGColor(red: 0.15, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// The stored RGBA bytes of an RGBA8 render, by pixel from the top left.
    private func rgba(_ image: CGImage) throws -> (Int, Int) -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let rowBytes = image.bytesPerRow
        let step = image.bitsPerPixel / 8
        return { x, y in
            let offset = y * rowBytes + x * step
            return [data[offset], data[offset + 1], data[offset + 2]]
        }
    }

    /// R, G, B of a BGRA surface pixel from the top left.
    private func surfacePixel(_ surface: IOSurface, x: Int, y: Int) throws -> [UInt8] {
        _ = surface.lock(options: .readOnly, seed: nil)
        defer { _ = surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let offset = y * surface.bytesPerRow + x * 4
        return [bytes[offset + 2], bytes[offset + 1], bytes[offset]]
    }
}
