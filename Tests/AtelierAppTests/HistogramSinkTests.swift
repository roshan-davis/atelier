import AppKit
import XCTest
@testable import AtelierApp

/// The histogram graph's target layer when views come and go (Rosh, Nov 16, 2026: the histogram
/// was black after Lens Blur's Save, because the old panel's histogram, dismantled after the new
/// one was made, cleared the new one's layer).
final class HistogramSinkTests: XCTestCase {
    private func picture() -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    func testAnOldViewGoingAwayKeepsTheNewViewsGraph() {
        let sink = HistogramSink()
        sink.reset(generation: 1)
        let old = CALayer(), new = CALayer()
        sink.setTarget(old)
        sink.setTarget(new)
        sink.detach(old)
        sink.present(picture(), generation: 1, rank: 1)
        XCTAssertNotNil(new.contents, "the new histogram view gets the graph")
        XCTAssertNil(old.contents)
    }

    func testTheShownViewGoingAwayStopsDrawing() {
        let sink = HistogramSink()
        sink.reset(generation: 1)
        let layer = CALayer()
        sink.setTarget(layer)
        sink.detach(layer)
        sink.present(picture(), generation: 1, rank: 1)
        XCTAssertNil(layer.contents)
    }
}
