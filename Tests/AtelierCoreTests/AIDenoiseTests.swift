import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// Detail > Noise Reduction > AI Denoise (AT-067): the noise measurement, the built-in PMRID model,
/// the tone-curve fit and how the noise picture is drawn. A real RAW file runs end to end only when
/// `ATELIER_DENOISE_RAW` (a file) or `ATELIER_SAMPLE_RAWS` (a folder) is set.
final class AIDenoiseTests: XCTestCase {
    /// Repeatable Gaussian noise (SplitMix64 and Box-Muller).
    private struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return (Double(z >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
    }

    /// Four planes of a smooth ramp (0.05...0.9) with noise of variance a × level + b.
    private func noisyRamp(width: Int, height: Int, a: Double, b: Double, seed: UInt64) -> [[Float]] {
        var noise = Noise(state: seed)
        return (0..<4).map { _ in
            var plane = [Float](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let level = 0.05 + 0.85 * Double(x) / Double(width) * (0.5 + 0.5 * Double(y) / Double(height))
                    plane[y * width + x] = Float(max(0, level + noise.gaussian() * (a * level + b).squareRoot()))
                }
            }
            return plane
        }
    }

    // MARK: Pieces

    func testHalfFloatsRoundTrip() {
        for value: Float in [0, 1, -1, 0.5, 0.0123, -0.0004, 3.75, 1e-6, 2000] {
            let back = FineEdges.floatFromHalf(AIDenoise.half(value))
            XCTAssertEqual(back, value, accuracy: max(abs(value) * 1e-3, 6e-8), "\(value)")
        }
        XCTAssertEqual(AIDenoise.half(1), 0x3C00)
        XCTAssertEqual(AIDenoise.half(70000), 0x7C00, "too large is infinity")
    }

    func testMirror() {
        XCTAssertEqual((-3...6).map { AIDenoise.mirror($0, 4) }, [3, 2, 1, 0, 1, 2, 3, 2, 1, 0])
        XCTAssertEqual(AIDenoise.mirror(5, 1), 0)
    }

    func testTheNoiseIsMeasuredOnThePhoto() throws {
        for (a, b) in [(0.002, 0.0001), (0.0005, 0.00002), (0.01, 0.0004)] {
            let planes = noisyRamp(width: 512, height: 512, a: a, b: b, seed: 7)
            let found = try XCTUnwrap(AIDenoise.estimate(planes, width: 512, height: 512))
            XCTAssertEqual(found.a, a, accuracy: a * 0.15, "signal-dependent part for \(a), \(b)")
            XCTAssertEqual(found.b, b, accuracy: b * 0.4 + a * 0.01, "constant part for \(a), \(b)")
        }
        XCTAssertNil(AIDenoise.estimate([[Float](repeating: 0.5, count: 64)], width: 8, height: 8), "too small")
    }

    func testTheModelTakesOutNoiseAcrossTiles() throws {
        try XCTSkipIf(AIDenoise.modelURL == nil, "PMRID.onnx isn't in the test bundle")
        // Not a multiple of the tile, so edge tiles reach past the photo.
        let width = 600, height = 520
        var noise = Noise(state: 3)
        let sigma = (0.002 * 0.3 + 0.0001).squareRoot()
        let planes = (0..<4).map { _ in (0..<(width * height)).map { _ in Float(0.3 + noise.gaussian() * sigma) } }
        let (out, _) = try AIDenoise.denoise(planes, width: width, height: height, noise: (0.002, 0.0001))
        func deviation(_ values: [[Float]]) -> Double {
            let all = values.flatMap { $0 }.map { Double($0) - 0.3 }
            return (all.reduce(0) { $0 + $1 * $1 } / Double(all.count)).squareRoot()
        }
        let before = deviation(planes), after = deviation(out)
        XCTAssertLessThan(after, before * 0.35, "PMRID removes most of the noise (\(before) → \(after))")
        let mean = out.flatMap { $0 }.reduce(0) { $0 + Double($1) } / Double(4 * width * height)
        XCTAssertEqual(mean, 0.3, accuracy: 0.02, "and keeps the level")
    }

    func testTheToneCurveIsFittedPerPhoto() {
        let linear = (0..<4000).map { Float($0) / 4000 * 1.2 + 0.0002 }
        let boosted = linear.map { $0.squareRoot() * 0.9 }
        let curve = AIDenoise.ChannelCurve.fit(linear: linear, boosted: boosted)
        for x: Float in [0.01, 0.1, 0.4, 0.8, 1.1] {
            XCTAssertEqual(curve(x), x.squareRoot() * 0.9, accuracy: 0.02, "\(x)")
        }
        XCTAssertGreaterThan(curve(1.5), curve(1.1), "straight on above the table")
        let flat = AIDenoise.ChannelCurve.fit(linear: [0, 0], boosted: [0, 0])
        XCTAssertEqual(flat(0.3), 0.3, accuracy: 1e-6, "nothing to fit is no curve")
    }

    func testTheNoiseIsSpreadToEveryPixelOfItsChannel() {
        // Red sites hold 1, green 2, blue 3: every pixel then holds 1, 2, 3.
        let pw = 5, ph = 4
        let sites = [Float(1), 2, 2, 3].map { [Float](repeating: $0, count: pw * ph) }
        let halves = AIDenoise.spread(sites, planeWidth: pw, planeHeight: ph, width: 2 * pw + 1, height: 2 * ph)
        for i in stride(from: 0, to: halves.count, by: 4) {
            XCTAssertEqual(FineEdges.floatFromHalf(halves[i]), 1, accuracy: 1e-3)
            XCTAssertEqual(FineEdges.floatFromHalf(halves[i + 1]), 2, accuracy: 1e-3)
            XCTAssertEqual(FineEdges.floatFromHalf(halves[i + 2]), 3, accuracy: 1e-3)
            XCTAssertEqual(FineEdges.floatFromHalf(halves[i + 3]), 1)
        }
    }

    // MARK: Drawing

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func value(_ image: CIImage, x: Int, yFromTop: Int) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        let y = Int(image.extent.maxY) - 1 - yFromTop
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: Int(image.extent.minX) + x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        return Array(pixel.prefix(3))
    }

    /// A noise picture of 0.1 in the top half and 0 in the bottom half of a 64 × 64 photo.
    private func topHalfResidual(mean: [Double]) -> AIDenoise.Residual {
        let width = 64, height = 64
        var halves = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                for c in 0..<3 { halves[i + c] = AIDenoise.half(y < height / 2 ? 0.1 : 0) }
                halves[i + 3] = AIDenoise.half(1)
            }
        }
        return AIDenoise.residual(halves, width: width, height: height, mean: mean)
    }

    func testTheNoiseIsTakenOutRightSideUpAndScaled() throws {
        try XCTSkipUnless(AIDenoise.kernelAvailable, "Metal kernels unavailable")
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let residual = topHalfResidual(mean: [0.5, 0.5, 0.5])
        let out = residual.apply(to: gray, amount: 1)
        XCTAssertEqual(value(out, x: 10, yFromTop: 4)[0], 0.4, accuracy: 0.002, "the top row of the bitmap is the top")
        XCTAssertEqual(value(out, x: 10, yFromTop: 60)[0], 0.5, accuracy: 0.002)
        XCTAssertEqual(residual.apply(to: gray, amount: 0.5).extent, gray.extent)
        XCTAssertEqual(value(residual.apply(to: gray, amount: 0.5), x: 10, yFromTop: 4)[1], 0.45, accuracy: 0.002)

        // A smaller decode, somewhere else, twice as bright (Exposure +1): the noise follows.
        let small = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 7, y: 9, width: 32, height: 32))
        let scaled = residual.apply(to: small, amount: 1)
        XCTAssertEqual(scaled.extent, small.extent)
        XCTAssertEqual(value(scaled, x: 16, yFromTop: 3)[2], 0.8, accuracy: 0.01)
        XCTAssertEqual(value(scaled, x: 16, yFromTop: 29)[2], 1, accuracy: 0.01)
    }

    func testOldEditsHaveNoAIDenoise() throws {
        let old = try DevelopSettings.decoded(from: #"{"schemaVersion":3,"luminanceNoise":20}"#)
        XCTAssertEqual(old[.aiDenoise], 0)
        var settings = DevelopSettings()
        settings[.aiDenoise] = 60
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded())[.aiDenoise], 60)
        XCTAssertEqual(DevelopSettings.Parameter.aiDenoise.group, "Noise Reduction")
        XCTAssertEqual(DevelopSettings.Parameter.aiDenoise.range, 0...100)
    }

    func testNotRAWNoEffectAndAStatusLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("denoise-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        cg.setFillColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(cg.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: nil))
        var settings = DevelopSettings()
        settings[.aiDenoise] = 80
        let plain = try XCTUnwrap(session.render(.neutral)), denoised = try XCTUnwrap(session.render(settings))
        XCTAssertEqual(plain.width, denoised.width)
        XCTAssertNil(AIDenoise.status(for: url), "nothing ran")
        XCTAssertEqual(AIDenoise.statusText(for: url, isRAW: false, amount: 80), "AI Denoise works on RAW photos only.")
        XCTAssertNil(AIDenoise.statusText(for: url, isRAW: false, amount: 0))
    }

    // MARK: A real RAW file

    /// The photo at full size without and with AI Denoise: noise (the spread of a Laplacian over
    /// the flattest blocks) drops, the level doesn't. Writes center crops to `ATELIER_SAMPLE_OUT`.
    func testARealRAWGetsLessNoisy() throws {
        let environment = ProcessInfo.processInfo.environment
        var files: [URL] = []
        if let file = environment["ATELIER_DENOISE_RAW"] { files.append(URL(fileURLWithPath: file)) }
        if let folder = environment["ATELIER_SAMPLE_RAWS"] {
            files += ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                                                                    includingPropertiesForKeys: nil)) ?? [])
                .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .rawImage) == true }
                .prefix(2)
        }
        if files.isEmpty { throw XCTSkip("No sample RAW files (set ATELIER_DENOISE_RAW)") }
        let output = environment["ATELIER_SAMPLE_OUT"].map { URL(fileURLWithPath: $0) }
        for url in files {
            let session = try XCTUnwrap(DevelopRenderer.shared.session(for: url, maxPixelSize: nil))
            var settings = DevelopSettings()
            settings[.aiDenoise] = 100
            let started = Date()
            let denoised = try XCTUnwrap(session.render(settings))
            let seconds = Date().timeIntervalSince(started)
            let status = AIDenoise.status(for: url)
            print("AI DENOISE \(url.lastPathComponent): \(denoised.width)×\(denoised.height) in \(String(format: "%.1f", seconds)) s, \(String(describing: status))")
            guard case .done = status else { return XCTFail("AI Denoise didn't run: \(String(describing: status))") }
            var off = DevelopSettings()
            off[.aiDenoise] = 0
            let before = try XCTUnwrap(session.render(off))
            let (noiseBefore, levelBefore) = try measure(before), (noiseAfter, levelAfter) = try measure(denoised)
            print("AI DENOISE \(url.lastPathComponent): noise \(noiseBefore) → \(noiseAfter), level \(levelBefore) → \(levelAfter)")
            XCTAssertLessThan(noiseAfter, noiseBefore, "less noise than Apple's own noise reduction")
            XCTAssertEqual(levelAfter, levelBefore, accuracy: 0.02, "same brightness")
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let name = url.deletingPathExtension().lastPathComponent
                try writeCrop(before, to: output.appendingPathComponent("denoise-\(name)-0-apple.png"))
                try writeCrop(denoised, to: output.appendingPathComponent("denoise-\(name)-100-ai.png"))
            }
        }
    }

    /// The median noise (Laplacian spread in 8 × 8 blocks of the gray value) and the mean gray value
    /// of the photo's center 1024 × 1024.
    private func measure(_ image: CGImage) throws -> (noise: Double, level: Double) {
        let side = min(1024, image.width, image.height)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                           width: side, height: side)))
        var gray = [UInt8](repeating: 0, count: side * side)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        XCTAssertTrue(drawn)
        var spreads: [Double] = []
        for by in stride(from: 1, to: side - 9, by: 8) {
            for bx in stride(from: 1, to: side - 9, by: 8) {
                var sum = 0.0, squares = 0.0
                for y in by..<(by + 8) {
                    for x in bx..<(bx + 8) {
                        let d = 4 * Double(gray[y * side + x]) - Double(gray[(y - 1) * side + x]) - Double(gray[(y + 1) * side + x])
                            - Double(gray[y * side + x - 1]) - Double(gray[y * side + x + 1])
                        sum += d
                        squares += d * d
                    }
                }
                spreads.append(max(0, squares / 64 - (sum / 64) * (sum / 64)).squareRoot())
            }
        }
        spreads.sort()
        let level = gray.reduce(0) { $0 + Double($1) } / Double(gray.count) / 255
        return (spreads[spreads.count / 2], level)
    }

    private func writeCrop(_ image: CGImage, to url: URL) throws {
        let side = min(800, image.width, image.height)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                           width: side, height: side)))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, crop, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
