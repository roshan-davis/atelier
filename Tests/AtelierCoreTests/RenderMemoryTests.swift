import CoreImage
import XCTest
@testable import AtelierCore

/// AT-077: what Develop keeps in Core Image's cache stays within a budget, so Lens Blur edits
/// can't pile up until the Mac runs out of memory (Rosh, Nov 16, 2026: 16 GB, Mac froze).
final class RenderMemoryTests: XCTestCase {
    func testBudgetScalesWithTheMac() {
        let gigabyte: UInt64 = 1_073_741_824
        XCTAssertEqual(RenderMemory.budget(physicalMemory: 4 * gigabyte), 512 * 1_048_576, "never below 512 MB")
        XCTAssertEqual(RenderMemory.budget(physicalMemory: 8 * gigabyte), Int(8 * gigabyte / 10), "8 GB Mac: a tenth")
        XCTAssertEqual(RenderMemory.budget(physicalMemory: 48 * gigabyte), 4 * Int(gigabyte), "never above 4 GB")
    }

    func testStageSizeIsItsPixelsInHalfFloats() {
        let stage = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(RenderMemory.estimatedBytes(of: stage), 100 * 50 * 8)
        XCTAssertEqual(RenderMemory.estimatedBytes(of: CIImage(color: .red)), 0, "infinite extents count as nothing")
    }

    func testKeptStagesClearTheCachePastTheBudget() {
        let memory = RenderMemory(context: CIContext(), budget: 100 * 1_048_576)
        let stage = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4000, height: 3000)) // ~92 MB
        _ = memory.kept(stage)
        XCTAssertEqual(memory.status.clears, 0, "the first stage fits")
        _ = memory.kept(stage)
        XCTAssertEqual(memory.status.clears, 1, "the second would pass the budget: cleared first")
        XCTAssertLessThanOrEqual(memory.status.keptBytes, memory.budget)
        memory.clear(because: "test")
        XCTAssertEqual(memory.status.keptBytes, 0)
        XCTAssertEqual(memory.status.lastReason, "test")
    }

    /// Forty Lens Blur edits on a 24 MP photo, each rendered at full size as the zoomed-in editor
    /// does: the process's memory (Activity Monitor's number) must not keep climbing. Before
    /// AT-077 each result stayed in Core Image's cache (about 190 MB each here).
    /// Opt-in (about a minute on a Mac): `ATELIER_MEMORY_TESTS=1 swift test --filter RenderMemoryTests`.
    func testLensBlurEditsDontPileUpInMemory() throws {
        guard ProcessInfo.processInfo.environment["ATELIER_MEMORY_TESTS"] == "1" else {
            throw XCTSkip("Set ATELIER_MEMORY_TESTS=1 to run the full-size memory test.")
        }
        XCTAssertTrue(LensBlur.kernelAvailable)
        let width = 6000, height = 4000
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // A textured photo and a left-to-right depth, made by Core Image (no 24 MP array in Swift).
        let photo = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 0.8, green: 0.6, blue: 0.4), "inputColor1": CIColor(red: 0.05, green: 0.1, blue: 0.2),
            "inputWidth": 7, "inputCenter": CIVector(x: 0, y: 0),
        ])!.outputImage!.cropped(to: extent)
        let depth = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(width), y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!.cropped(to: extent)
        let context = DevelopRenderer.shared.context
        let rowBytes = width * 8
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 64)
        defer { buffer.deallocate() }
        RenderMemory.shared.clear(because: "test start")
        let start = try XCTUnwrap(RenderMemory.footprint())
        var peak = start
        var settings = DevelopSettings()
        settings[.lensBlurApply] = 1
        settings[.lensBlurFocusNear] = 0
        settings[.lensBlurFocusFar] = 10
        for edit in 0..<40 {
            // A new Amount each time, as a slider drag or a new stroke makes a new result.
            settings[.lensBlurAmount] = 30 + Double(edit)
            let blurred = LensBlur.apply(photo, depth: depth, settings: settings, context: context)
            context.render(blurred, toBitmap: buffer, rowBytes: rowBytes, bounds: extent, format: .RGBAh, colorSpace: nil)
            let now = try XCTUnwrap(RenderMemory.footprint())
            peak = max(peak, now)
            print("RenderMemoryTests: edit \(edit + 1): \(now / 1_048_576) MB (clears \(RenderMemory.shared.status.clears))")
        }
        RenderMemory.shared.clear(because: "test end")
        let end = try XCTUnwrap(RenderMemory.footprint())
        print("RenderMemoryTests: start \(start / 1_048_576) MB, peak \(peak / 1_048_576) MB, after clear \(end / 1_048_576) MB, budget \(RenderMemory.shared.budget / 1_048_576) MB")
        let allowance = UInt64(RenderMemory.shared.budget) + 1_536 * 1_048_576
        XCTAssertLessThan(peak - start, allowance, "Lens Blur results piled up past the budget")
        XCTAssertLessThan(end - start, 1_536 * 1_048_576, "clearing lets the results go")
    }
}
