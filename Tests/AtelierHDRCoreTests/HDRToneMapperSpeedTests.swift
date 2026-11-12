import XCTest
import CoreGraphics
@testable import AtelierHDRCore

/// The faster tone mapper (kept exposure analysis, work split across cores, Nov 12, 2026) must
/// give exactly the same pixels as the single-threaded version it replaced, which is kept
/// below verbatim as the reference.
final class HDRToneMapperSpeedTests: XCTestCase {
    /// A 400x267 test photo with gradients, texture and hard edges, values from deep black to
    /// well above white.
    private func sample(width: Int = 400, height: Int = 267) throws -> HDRImage {
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                let gradient = powf(2, Float(x) / Float(width) * 12 - 9)
                let texture: Float = 1 + 0.3 * sinf(Float(x) * 0.7) * cosf(Float(y) * 0.45)
                let edge: Float = (x / 37 + y / 29) % 2 == 0 ? 1 : 0.2
                let l = gradient * texture * edge
                rgb[i] = l; rgb[i+1] = l * 0.8; rgb[i+2] = l * 0.55
            }
        }
        return try HDRImage(width: width, height: height, rgb: rgb)
    }

    private var settingsToTry: [HDRSettings] {
        var list: [HDRSettings] = [HDRSettings()]
        var s = HDRSettings(); s.exposure = 1.3; s.compression = 1; s.microcontrast = -0.7; s.detail = 1; list.append(s)
        s = HDRSettings(); s.exposure = -2; s.compression = 0; s.shadowProtection = 0; s.highlightProtection = 1; list.append(s)
        s = HDRSettings(); s.artifactsEnabled = false; s.microcontrast = 1; list.append(s)
        s = HDRSettings(); s.method = .virtualExposureFusion; s.compression = 0.4; list.append(s)
        s = HDRSettings(); s.method = .fusion; list.append(s)
        s = HDRSettings(); s.method = .fusion; s.fusionSpacing = 3; s.compression = 1; list.append(s)
        s = HDRSettings(); s.toneEnabled = false; list.append(s)
        return list
    }

    func testMatchesTheSingleThreadedRendererExactly() throws {
        let image = try sample()
        for settings in settingsToTry {
            let reference = try SerialReferenceToneMapper.render(image, settings: settings)
            XCTAssertEqual(try HDRToneMapper.render(image, settings: settings).rgb, reference.rgb)
            let analysis = try HDRToneMapper.analyze(image, exposure: settings.exposure)
            XCTAssertEqual(try HDRToneMapper.render(image, settings: settings, analysis: analysis).rgb, reference.rgb)
        }
    }

    func testAnalysisFromAnotherExposureOrSizeIsNotUsed() throws {
        let image = try sample()
        let other = try HDRToneMapper.analyze(image, exposure: 2)
        var settings = HDRSettings(); settings.exposure = -1
        XCTAssertEqual(try HDRToneMapper.render(image, settings: settings, analysis: other).rgb,
                       try SerialReferenceToneMapper.render(image, settings: settings).rgb)
        let small = try sample(width: 120, height: 80)
        XCTAssertFalse(other.matches(small, exposure: 2))
        XCTAssertEqual(try HDRToneMapper.render(small, settings: HDRSettings(),
                                                analysis: try HDRToneMapper.analyze(image, exposure: 0)).rgb,
                       try SerialReferenceToneMapper.render(small, settings: HDRSettings()).rgb)
    }

    /// Timings for the PR (Atelier HDR's 1600 px slider proxy): a fresh render (what an Exposure
    /// drag does), one with the analysis kept (every other slider) and the preview image.
    /// Printed, not asserted, as machines differ. The reference copy above lives in this test
    /// target, which isn't optimized in Debug, so it isn't timed here: compare with main's
    /// `HDRToneMapper.render` instead (same call, same image).
    func testPrintsProxyRenderTimings() throws {
        let image = try sample(width: 1600, height: 1067)
        let settings = HDRSettings()
        func time(_ body: () throws -> Void) rethrows -> Double {
            var best = Double.infinity
            for _ in 0..<3 {
                let start = Date(); try body(); best = min(best, Date().timeIntervalSince(start))
            }
            return best * 1000
        }
        let fresh = try time { _ = try HDRToneMapper.render(image, settings: settings) }
        let analysis = try HDRToneMapper.analyze(image, exposure: settings.exposure)
        let kept = try time { _ = try HDRToneMapper.render(image, settings: settings, analysis: analysis) }
        let io = HDRImageIO(), rendered = try HDRToneMapper.render(image, settings: settings, analysis: analysis)
        let preview = try time { _ = try io.preview(rendered) }
        print(String(format: "HDR 1600x1067 render ms: fresh %.1f, analysis kept %.1f, preview %.1f",
                     fresh, kept, preview))
        // The GPU path a slider drag takes (`HDRPreviewRenderer`): the upload once per Exposure,
        // then kernel plus read-back per frame (live frames skip the read-back).
        if let renderer = HDRPreviewRenderer.shared {
            var source: HDRPreviewRenderer.Source?
            let upload = time { source = renderer.source(image, analysis: analysis) }
            let gpu = try time {
                let frame = try XCTUnwrap(source.flatMap { renderer.image($0, settings: settings) })
                _ = try XCTUnwrap(renderer.cgImage(frame))
            }
            print(String(format: "HDR 1600x1067 GPU ms: upload %.1f, frame with read-back %.1f", upload, gpu))
        }
    }

    /// The GPU preview kernel draws what the CPU tone mapper does, within a step or two of the
    /// 8-bit preview, the same way up.
    func testGPUPreviewMatchesTheCPURenderer() throws {
        guard let renderer = HDRPreviewRenderer.shared else {
            throw XCTSkip("The HDR preview kernel didn't build on this Mac.")
        }
        let image = try sample(), io = HDRImageIO()
        var regions = HDRSettings(); regions.shadows = 0.8; regions.highlights = -0.6
        var fusion = regions; fusion.method = .virtualExposureFusion; fusion.shadows = -0.5
        var blend = regions; blend.method = .fusion; blend.fusionSpacing = 1.5
        for settings in settingsToTry + [regions, fusion, blend] {
            let analysis = try HDRToneMapper.analyze(image, exposure: settings.exposure)
            let source = try XCTUnwrap(renderer.source(image, analysis: analysis))
            let frame = try XCTUnwrap(renderer.image(source, settings: settings))
            let gpu = try bytes(try XCTUnwrap(renderer.cgImage(frame)))
            let cpu = try bytes(try io.preview(try HDRToneMapper.render(image, settings: settings)))
            XCTAssertEqual(gpu.count, cpu.count)
            let worst = zip(gpu, cpu).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 2, "\(settings)")
        }
    }

    /// Highlights and Shadows (Nov 12, 2026) move the bright and dark regions, as Develop's do,
    /// and at 0 change nothing.
    func testShadowsAndHighlightsMoveTheirRegions() throws {
        let image = try sample()
        let plain = try HDRToneMapper.render(image, settings: HDRSettings()).rgb
        func mean(_ rgb: [Float], _ include: (Float) -> Bool) -> Float {
            var sum: Float = 0, count: Float = 0
            for i in stride(from: 0, to: rgb.count, by: 3) where include(plain[i + 1]) {
                sum += rgb[i + 1]; count += 1
            }
            return sum / max(1, count)
        }
        let dark: (Float) -> Bool = { $0 > 0.005 && $0 < 0.05 }
        let bright: (Float) -> Bool = { $0 > 0.4 }
        var lifted = HDRSettings(); lifted.shadows = 1
        let shadowsUp = try HDRToneMapper.render(image, settings: lifted).rgb
        XCTAssertGreaterThan(mean(shadowsUp, dark), mean(plain, dark) * 1.2)
        var recovered = HDRSettings(); recovered.highlights = -1
        let highlightsDown = try HDRToneMapper.render(image, settings: recovered).rgb
        XCTAssertLessThan(mean(highlightsDown, bright), mean(plain, bright) * 0.95)
        // Each leaves the other end almost alone.
        XCTAssertEqual(mean(highlightsDown, dark), mean(plain, dark), accuracy: mean(plain, dark) * 0.2)
        // Old projects (no Shadows or Highlights) decode to 0.
        let old = try JSONDecoder().decode(HDRSettings.self, from: Data(#"{"compression":0.5}"#.utf8))
        XCTAssertEqual(old.shadows, 0); XCTAssertEqual(old.highlights, 0)
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}

enum SerialReferenceToneMapper {
    static func render(_ image: HDRImage, settings: HDRSettings,
                              cancellation: () throws -> Void = {}) throws -> HDRImage {
        try settings.validate()
        try cancellation()
        if !settings.toneEnabled { return image }
        let count = image.width * image.height
        let gain = powf(2, settings.exposure)
        var luminance = [Float](repeating: 0, count: count)
        for i in 0..<count {
            luminance[i] = max(0, (image.rgb[i*3] * 0.2126 + image.rgb[i*3+1] * 0.7152
                                   + image.rgb[i*3+2] * 0.0722) * gain)
        }
        // Spatial scales are relative to full image geometry, so proxy/full-size controls
        // address the same structures. Edge protection limits amplified large transitions.
        let logs = luminance.map { log2f(max($0, 0.000001)) }
        let small = try blur(logs, width: image.width, height: image.height,
                             radius: max(1, Int(Float(max(image.width, image.height)) * 0.002)), cancellation: cancellation)
        let large = try guidedBase(logs, width: image.width, height: image.height,
                             radius: max(1, Int(Float(max(image.width, image.height)) * 0.02)), cancellation: cancellation)
        var output = image.rgb
        for y in 0..<image.height {
            try cancellation()
            for x in 0..<image.width {
                let i = y * image.width + x, l = luminance[i]
                let mapped: Float
                switch settings.method {
                case .direct:
                    // Compress large-scale log illumination around middle gray, retaining
                    // the edge-aware residual. The guided base prevents wide texture halos.
                    let anchor = log2f(0.18)
                    // Keep deep blacks from turning gray as the illumination range compresses.
                    let blackProtection = min(1, max(0, l / 0.06))
                    let amount = settings.compression * (large[i] < anchor ? blackProtection : 1)
                    let base = anchor + (large[i] - anchor) * (1 - amount * 0.85)
                    let local = settings.compression == 0 ? l : exp2f(base + logs[i] - large[i])
                    // Restore midtone separation after illumination compression. This avoids
                    // equating an HDR look with a uniformly lifted, low-contrast image.
                    let shaped = settings.compression == 0 ? local : 0.18 * powf(max(0, local / 0.18), 1.25)
                    let k = settings.compression
                    mapped = shaped * (1 + k * 0.18) / (1 + k * shaped)
                case .virtualExposureFusion:
                    // Explicit -2/0/+2 EV display plates, normalized positive well-exposedness
                    // weights. This is a global baseline for comparison, not Mertens pyramids.
                    var sum: Float = 0, weights: Float = 0
                    for ev: Float in [-2, 0, 2] {
                        let plate = min(1, l * powf(2, ev))
                        let weight = expf(-powf((plate - 0.5) / 0.24, 2) / 2) + 0.0001
                        sum += plate * weight; weights += weight
                    }
                    let fused = sum / weights
                    mapped = l * (1 - settings.compression) + fused * settings.compression
                case .fusion:
                    // Added after the speed work (Nov 12, 2026); the same per-pixel function.
                    mapped = HDRToneMapper.fusion(l: l, large: large[i], spacing: settings.fusionSpacing,
                                                  amount: settings.compression)
                }
                let shadowMask = min(1, l / 0.08)
                let highlightMask = 1 / (1 + max(0, l - 0.7) * 4)
                let protection: Float = settings.artifactsEnabled ? (1 - settings.shadowProtection + settings.shadowProtection * shadowMask)
                    * (1 - settings.highlightProtection + settings.highlightProtection * highlightMask) : 1
                let fine = max(-0.5, min(0.5, logs[i] - small[i]))
                let coarse = max(-0.5, min(0.5, small[i] - large[i]))
                let boundaryProtection = 1 / (1 + abs(logs[i] - small[i]) * 4)
                let texture = powf(2, protection * (settings.detail * fine * 2
                    + settings.microcontrast * coarse * 3 * boundaryProtection))
                let scale = l > 0.000001 ? mapped / l * gain * texture : gain
                for c in 0..<3 { output[i*3+c] = max(0, image.rgb[i*3+c] * scale) }
            }
        }
        return try HDRImage(width: image.width, height: image.height, rgb: output)
    }

    /// Self-guided filter in log2 luminance. Epsilon is in squared stops; the base
    /// follows strong boundaries while smoothing illumination within textured surfaces.
    private static func guidedBase(_ values: [Float], width: Int, height: Int, radius: Int,
                                   cancellation: () throws -> Void) throws -> [Float] {
        let mean = try blur(values, width: width, height: height, radius: radius, cancellation: cancellation)
        let squares = values.map { $0 * $0 }
        let meanSquare = try blur(squares, width: width, height: height, radius: radius, cancellation: cancellation)
        var a = mean, b = mean
        for i in values.indices {
            let variance = max(0, meanSquare[i] - mean[i] * mean[i])
            a[i] = variance / (variance + 0.12)
            b[i] = (1 - a[i]) * mean[i]
        }
        let meanA = try blur(a, width: width, height: height, radius: radius, cancellation: cancellation)
        let meanB = try blur(b, width: width, height: height, radius: radius, cancellation: cancellation)
        return values.indices.map { meanA[$0] * values[$0] + meanB[$0] }
    }

    /// Separable sliding-window mean with replicated borders; bounded O(pixel count) work.
    private static func blur(_ values: [Float], width: Int, height: Int, radius: Int,
                             cancellation: () throws -> Void) throws -> [Float] {
        var horizontal = values, result = values
        let r = min(radius, max(width, height)), divisor = Float(2*r+1)
        for y in 0..<height {
            try cancellation()
            var sum: Float = 0
            for dx in -r...r { sum += values[y*width + min(width-1, max(0, dx))] }
            for x in 0..<width {
                horizontal[y*width+x] = sum / divisor
                sum += values[y*width + min(width-1, x+r+1)] - values[y*width + max(0, x-r)]
            }
        }
        for x in 0..<width {
            try cancellation()
            var sum: Float = 0
            for dy in -r...r { sum += horizontal[min(height-1, max(0, dy))*width+x] }
            for y in 0..<height {
                result[y*width+x] = sum / divisor
                sum += horizontal[min(height-1, y+r+1)*width+x] - horizontal[max(0, y-r)*width+x]
            }
        }
        return result
    }
}
