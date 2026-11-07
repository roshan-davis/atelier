import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// Before/after timings for Develop slider drags on real RAW files (CI downloads them into
/// ATELIER_SAMPLE_RAWS). "Before" is what the render queue did per tick before PR #79: a session
/// without the step-1 cache, the color cube built on one core, the histogram and color scope
/// counted before the photo is shown, and the clipping overlay as a second upload and readback.
/// "After" is the new path. Prints a Markdown table (lines start with "PERF") and writes it to
/// ATELIER_SAMPLE_OUT/slider-performance.md.
final class SliderPerformanceTests: XCTestCase {
    private struct Slider {
        let name: String
        /// Sets the slider for tick `i` (each tick a new value, as a drag gives).
        let set: (inout DevelopSettings, Int) -> Void
        /// Whether the slider is read by pipeline step 1 (decode, lens, Transform).
        var stepOne = false
    }

    private static func parameter(_ name: String, _ parameter: DevelopSettings.Parameter, start: Double, step: Double,
                                  stepOne: Bool = false) -> Slider {
        Slider(name: name, set: { $0[parameter] = start + Double($1) * step }, stepOne: stepOne)
    }

    private static let sliders: [Slider] = [
        parameter("Basic > Contrast", .contrast, start: 10, step: 4),
        parameter("Basic > Highlights", .highlights, start: -10, step: -4),
        parameter("Basic > Shadows", .shadows, start: 10, step: 4),
        parameter("Basic > Whites", .whites, start: 5, step: 3),
        parameter("Basic > Blacks", .blacks, start: -5, step: -3),
        parameter("Presence > Texture", .texture, start: 10, step: 4),
        parameter("Presence > Clarity", .clarity, start: 10, step: 4),
        parameter("Presence > Dehaze", .dehaze, start: 10, step: 4),
        parameter("Presence > Vibrance", .vibrance, start: 10, step: 4),
        parameter("Presence > Saturation", .saturation, start: 10, step: 4),
        parameter("Tone Curve > Lights", .curveLights, start: 10, step: 4),
        parameter("HSL > Saturation Red", .satRed, start: 10, step: 4),
        parameter("HSL > Hue Blue", .hueBlue, start: 5, step: 3),
        Slider(name: "Color Grading > Midtones wheel", set: { settings, i in
            settings[.gradeMidtonesHue] = 30 + Double(i) * 6
            settings[.gradeMidtonesSat] = 20
        }),
        parameter("Detail > Sharpening", .sharpening, start: 30, step: 5),
        parameter("Detail > Noise Reduction", .luminanceNoise, start: 10, step: 4),
        parameter("Effects > Vignetting", .vignette, start: -10, step: -4),
        parameter("Effects > Grain", .grain, start: 10, step: 4),
        parameter("Effects > Glow", .glowAmount, start: 10, step: 4),
        parameter("Basic > Exposure", .exposure, start: 0.1, step: 0.05, stepOne: true),
        Slider(name: "Basic > Temp", set: { settings, i in settings.temperature = 5000 + Double(i) * 50 }, stepOne: true),
        parameter("Lens Corrections > Distortion", .lensDistortion, start: 5, step: 2, stepOne: true),
        parameter("Transform > Vertical", .transformVertical, start: 5, step: 2, stepOne: true),
    ]

    private struct Row {
        let file: String
        let slider: String
        let size: String
        let before: Double
        let after: Double
        let histogram: Double?
    }

    func testSliderTimingsBeforeAndAfter() throws {
        guard let folder = ProcessInfo.processInfo.environment["ATELIER_SAMPLE_RAWS"] else {
            throw XCTSkip("No sample RAW files")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                                                                includingPropertiesForKeys: nil)
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .rawImage) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.isEmpty { throw XCTSkip("No sample RAW files downloaded") }
        defer { ColorLUT.buildsInParallel = true }

        var rows: [Row] = []
        for url in files {
            let name = url.lastPathComponent
            // The live proxy (2560 px), every slider.
            for slider in Self.sliders {
                rows.append(try measure(url, name: name, slider: slider, size: 2560, ticks: 6, clipping: false))
            }
            // J on, for two sliders.
            for slider in Self.sliders where ["Basic > Contrast", "HSL > Saturation Red"].contains(slider.name) {
                rows.append(try measure(url, name: name, slider: slider, size: 2560, ticks: 6, clipping: true))
            }
        }
        // Full size (zoomed past fit) on the first file, two sliders, fewer ticks.
        if let url = files.first {
            for slider in Self.sliders where ["Basic > Contrast", "HSL > Saturation Red"].contains(slider.name) {
                rows.append(try measure(url, name: url.lastPathComponent, slider: slider, size: nil, ticks: 3,
                                        clipping: false))
            }
        }

        var lines = ["| File | Slider | Render | Before (ms/tick) | After (ms/tick) | Speed-up | After: histogram off the render queue (ms) |",
                     "|---|---|---|---:|---:|---:|---:|"]
        for row in rows {
            let speedup = row.after > 0 ? row.before / row.after : 0
            lines.append(String(format: "| %@ | %@ | %@ | %.0f | %.0f | %.2f× | %@ |", row.file, row.slider, row.size,
                                row.before, row.after, speedup, row.histogram.map { String(format: "%.0f", $0) } ?? "–"))
        }
        let table = lines.joined(separator: "\n")
        for line in lines { print("PERF " + line) }
        if let output = ProcessInfo.processInfo.environment["ATELIER_SAMPLE_OUT"] {
            let folder = URL(fileURLWithPath: output)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? (table + "\n").write(to: folder.appendingPathComponent("slider-performance.md"), atomically: true,
                                      encoding: .utf8)
        }
    }

    /// Median time per tick for one slider drag, before and after. Each side has its own
    /// renderer, so neither sees the other's Core Image cache, and one untimed warm-up tick
    /// opens the photo (as in Develop, where the photo is already open when you drag).
    private func measure(_ url: URL, name: String, slider: Slider, size: Int?, ticks: Int,
                         clipping: Bool) throws -> Row {
        let sizeName = (size.map { "\($0) px" } ?? "full size") + (clipping ? ", J on" : "")

        // Before.
        ColorLUT.buildsInParallel = false
        let oldRenderer = DevelopRenderer()
        let old = try XCTUnwrap(oldRenderer.session(for: url, maxPixelSize: size))
        var beforeTimes: [Double] = []
        for tick in 0...ticks {
            var settings = DevelopSettings()
            slider.set(&settings, tick)
            let start = DispatchTime.now()
            let rendered = try XCTUnwrap(old.render(settings))
            var shown = rendered
            if clipping { shown = try XCTUnwrap(ClippingOverlay.apply(to: rendered, shadows: true, highlights: true)) }
            if size != nil {
                _ = Histogram(image: rendered)
                _ = ColorScope(image: rendered)
            }
            _ = shown
            if tick > 0 { beforeTimes.append(Self.milliseconds(since: start)) }
        }

        // After.
        ColorLUT.buildsInParallel = true
        let newRenderer = DevelopRenderer()
        let new = try XCTUnwrap(newRenderer.session(for: url, maxPixelSize: size, interactive: true))
        var afterTimes: [Double] = []
        var histogramTimes: [Double] = []
        for tick in 0...ticks {
            var settings = DevelopSettings()
            slider.set(&settings, tick)
            let start = DispatchTime.now()
            let rendered = try XCTUnwrap(new.renderForDisplay(settings, shadowClipping: clipping, highlightClipping: clipping))
            if tick > 0 { afterTimes.append(Self.milliseconds(since: start)) }
            if size != nil {
                let measured = DispatchTime.now()
                _ = Histogram(image: rendered.plain)
                _ = ColorScope(image: rendered.plain)
                if tick > 0 { histogramTimes.append(Self.milliseconds(since: measured)) }
            }
        }
        return Row(file: name, slider: slider.name + (slider.stepOne ? " (step 1)" : ""), size: sizeName,
                   before: Self.median(beforeTimes), after: Self.median(afterTimes),
                   histogram: histogramTimes.isEmpty ? nil : Self.median(histogramTimes))
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
