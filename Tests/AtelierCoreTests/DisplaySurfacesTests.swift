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

    /// A zoomed detail frame is the visible part of the ordinary render, the right way up.
    func testZoomedDetailMatchesThatPartOfTheOrdinaryRender() throws {
        let file = workDir.appendingPathComponent("detail.png")
        try makeHalves(at: file, width: 60, height: 40)
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: file, maxPixelSize: nil))
        var settings = DevelopSettings()
        settings.contrast = 30
        let ordinary = try XCTUnwrap(session.renderForDisplay(settings)).image
        let expected = try rgba(ordinary)
        let surfaces = DisplaySurfaces(limit: 2)
        // The middle band across the top/bottom edge, right half: 30 × 20 pixels from (30, 10).
        let visible = CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        let surface = try XCTUnwrap(session.renderZoomedDetail(settings, visible: visible,
                                                               pixels: CGSize(width: 60, height: 40), surfaces: surfaces))
        XCTAssertEqual(surface.width, 30)
        XCTAssertEqual(surface.height, 20)
        for (x, y) in [(2, 2), (25, 6), (4, 15), (27, 18)] {
            let want = expected(30 + x, 10 + y)
            let got = try surfacePixel(surface, x: x, y: y)
            for channel in 0..<3 {
                XCTAssertEqual(Int(got[channel]), Int(want[channel]), accuracy: 1, "pixel (\(x), \(y)) channel \(channel)")
            }
        }
        // Fewer screen pixels than the region has: scaled down to them.
        let small = try XCTUnwrap(session.renderZoomedDetail(settings, visible: visible,
                                                             pixels: CGSize(width: 15, height: 10), surfaces: surfaces))
        XCTAssertEqual(small.width, 15)
        XCTAssertEqual(small.height, 10)
    }

    func testZoomedDetailRegion() throws {
        let extent = CGRect(x: 0, y: 0, width: 6000, height: 4000)
        // Top-left quarter at 100% on a 3000 × 2000 pixel view: no scaling, top of the photo.
        let top = try XCTUnwrap(ZoomedDetail.region(of: extent, visible: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                                    pixels: CGSize(width: 3000, height: 2000)))
        XCTAssertEqual(top.source, CGRect(x: 0, y: 2000, width: 3000, height: 2000))
        XCTAssertEqual(top.scale, 1)
        XCTAssertEqual(top.size, CGSize(width: 3000, height: 2000))
        // At 50%: half the pixels.
        let half = try XCTUnwrap(ZoomedDetail.region(of: extent, visible: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5),
                                                     pixels: CGSize(width: 1500, height: 1000)))
        XCTAssertEqual(half.source, CGRect(x: 1500, y: 0, width: 3000, height: 2000))
        XCTAssertEqual(half.scale, 0.5)
        XCTAssertEqual(half.size, CGSize(width: 1500, height: 1000))
        // Past 100% the screen magnifies; the frame is never larger than the region.
        let close = try XCTUnwrap(ZoomedDetail.region(of: extent, visible: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                                      pixels: CGSize(width: 3000, height: 2000)))
        XCTAssertEqual(close.size, CGSize(width: 600, height: 400))
        XCTAssertNil(ZoomedDetail.region(of: extent, visible: .zero, pixels: CGSize(width: 10, height: 10)))
        // A 2560 px proxy has the pixels for a 1000 px view of 40% of it, not for 3000 px.
        XCTAssertTrue(ZoomedDetail.isSharpEnough(imageWidth: 2560, visibleWidth: 0.4, screenPixels: 1000))
        XCTAssertFalse(ZoomedDetail.isSharpEnough(imageWidth: 2560, visibleWidth: 0.4, screenPixels: 3000))
    }

    func testDrainLetsGoOfThePool() {
        let surfaces = DisplaySurfaces(limit: 1)
        let first = surfaces.checkOut(width: 8, height: 8)
        XCTAssertNotNil(first)
        XCTAssertNil(surfaces.checkOut(width: 8, height: 8))
        surfaces.drain()
        // The one out is dropped when it comes back; a new one can be made.
        if let first { surfaces.checkIn(first) }
        let second = surfaces.checkOut(width: 8, height: 8)
        XCTAssertNotNil(second)
        XCTAssertFalse(second === first)
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
