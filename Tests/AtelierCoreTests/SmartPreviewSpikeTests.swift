import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import XCTest
@testable import AtelierCore

/// AT-079d feasibility: the DNG container is valid everywhere; on a Mac with sample RAWs
/// (`ATELIER_SAMPLE_RAWS`, output to `ATELIER_SAMPLE_OUT`) each RAW is written as a lossless and
/// a lossy smart preview, both are opened with CIRAWFilter, and their renders at several white
/// balances and exposures are compared with the RAW's own at the same size.
final class SmartPreviewSpikeTests: XCTestCase {
    func testWhiteFollowsTemperature() {
        // D65 sits just off the Planckian locus (on the green side), so 6504 K at tint 0 reads a
        // few percent from (1, 1, 1).
        let d65 = SmartPreviewDNG.neutral(temperature: 6504, tint: 0)
        XCTAssertEqual(d65.x, 1, accuracy: 0.06)
        XCTAssertEqual(d65.y, 1, accuracy: 0.06)
        XCTAssertEqual(d65.z, 1, accuracy: 0.06)
        let tungsten = SmartPreviewDNG.neutral(temperature: 3000, tint: 0)
        XCTAssertGreaterThan(tungsten.x, tungsten.z * 1.5, "warm light reads red-heavy")
        let magenta = SmartPreviewDNG.whiteXY(temperature: 5000, tint: 30)
        let neutral = SmartPreviewDNG.whiteXY(temperature: 5000, tint: 0)
        XCTAssertLessThan(magenta.1, neutral.1, "positive tint moves away from green")
    }

    /// A synthetic photo round-trips through ImageIO's DNG reader in both encodings.
    func testWrittenDNGOpens() throws {
        let width = 300, height = 200
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = Float(x) / Float(width) * 0.5
                rgba[i + 1] = 0.25
                rgba[i + 2] = Float(y) / Float(height) * 0.5
                rgba[i + 3] = 1
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SmartPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, encoding) in [("lossless", SmartPreviewDNG.Encoding.lossless16), ("lossy", .lossyJPEG(quality: 0.9))] {
            let url = folder.appendingPathComponent("\(name).dng")
            try SmartPreviewDNG.write(rgba: rgba, width: width, height: height,
                                      neutral: SmartPreviewDNG.neutral(temperature: 5000, tint: 0),
                                      make: "Nikon", model: "Z f", encoding: encoding, to: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), name)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            print("SMARTPREVIEW synthetic \(name): \(try Data(contentsOf: url).count) bytes, type \(CGImageSourceGetType(source) as String? ?? "?"), \(properties?[kCGImagePropertyPixelWidth] ?? "?")x\(properties?[kCGImagePropertyPixelHeight] ?? "?")")
            let filter = CIRAWFilter(imageURL: url)
            print("SMARTPREVIEW synthetic \(name): CIRAWFilter \(filter == nil ? "nil" : "ok"), output \(filter?.outputImage?.extent.debugDescription ?? "nil")")
        }
    }

    /// Does CIRAWFilter white-balance the DNG from its AsShotNeutral and the Temp/Tint it is given?
    /// A grey card shot under 3000, 5000 and 8000 K (the card times each light's neutral) is written
    /// with that neutral; each is then opened as shot, and at 3000, 5000 and 8000 K. Printed: the
    /// as-shot temperature and tint CIRAWFilter reports, and the card's rendered linear RGB.
    func testWhiteBalanceFollowsTheNeutral() throws {
        let width = 512, height = 512
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SmartPreviewWB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = CIContext(options: [.cacheIntermediates: false])
        let linear = CGColorSpace(name: CGColorSpace.linearITUR_2020)!
        for light in [3000.0, 5000, 8000] {
            let rgba = [Float](repeating: 0.18, count: width * height * 4)  // alpha is not written
            let neutral = SmartPreviewDNG.neutral(temperature: light, tint: 0)
            for (name, encoding, balanced) in [("lossless", SmartPreviewDNG.Encoding.lossless16, false),
                                               ("lossy", .lossyJPEG(quality: 0.9), false),
                                               ("lossy balanced", .lossyJPEG(quality: 0.9), true)] {
                let url = folder.appendingPathComponent("card-\(Int(light))-\(name).dng")
                try SmartPreviewDNG.write(rgba: rgba, width: width, height: height, neutral: neutral,
                                          make: "Nikon", model: "Z f", encoding: encoding, balancedCamera: balanced, to: url)
                guard let shot = CIRAWFilter(imageURL: url) else {
                    XCTFail("CIRAWFilter can't open the \(Int(light))K \(name) card"); continue
                }
                print(String(format: "SMARTPREVIEW WB card under %dK %@: neutral %.3f/%.3f/%.3f, reported as shot %.0f K tint %.1f, baseline %.2f",
                             Int(light), name, neutral.x, neutral.y, neutral.z, shot.neutralTemperature, shot.neutralTint, shot.baselineExposure))
                for temperature in [Float?.none, 3000, 5000, 8000] {
                    guard let filter = CIRAWFilter(imageURL: url) else { continue }
                    filter.boostAmount = 0
                    if let temperature { filter.neutralTemperature = temperature }
                    guard let image = filter.outputImage else { print("SMARTPREVIEW WB: no output"); continue }
                    var pixel = [Float](repeating: 0, count: 4)
                    let center = CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1)
                    context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: center, format: .RGBAf, colorSpace: linear)
                    print(String(format: "SMARTPREVIEW WB   at %@: card %.4f/%.4f/%.4f", temperature.map { "\(Int($0))K" } ?? "as shot",
                                 pixel[0], pixel[1], pixel[2]))
                    if temperature == nil, name != "lossy" {  // unbalanced lossy: known chroma error (round 6)
                        XCTAssertGreaterThan(pixel[1], 0.05, "\(name) card under \(Int(light))K renders")
                        XCTAssertEqual(pixel[0] / pixel[1], 1, accuracy: 0.03, "\(name) card under \(Int(light))K is grey as shot")
                        XCTAssertEqual(pixel[2] / pixel[1], 1, accuracy: 0.03, "\(name) card under \(Int(light))K is grey as shot")
                    }
                }
            }
        }
    }

    /// Which lossy DNGs CIRAWFilter can read: sizes × content (flat, gradient, noisy). Then a noisy
    /// grey card at 2560 × 1706 under 5000 K, lossless against lossy, at as shot, 3000, 4000 and 8000 K.
    func testWhichLossyDNGsOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SmartPreviewLossy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var seed: UInt64 = 1
        func noise() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) - 0.5 }
        func card(_ width: Int, _ height: Int, _ content: String) -> [Float] {
            var rgba = [Float](repeating: 0.18, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    for c in 0..<3 {
                        switch content {
                        case "gradient": rgba[i + c] = 0.05 + 0.4 * Float(x + y) / Float(width + height)
                        case "noisy": rgba[i + c] = 0.18 * (1 + 0.3 * noise())
                        default: break
                        }
                    }
                }
            }
            return rgba
        }
        let neutral = SmartPreviewDNG.neutral(temperature: 5000, tint: 0)
        for (width, height) in [(512, 512), (1024, 683), (2048, 1365), (2560, 1706)] {
            for content in ["flat", "gradient", "noisy"] {
                let url = folder.appendingPathComponent("\(width)-\(content).dng")
                try SmartPreviewDNG.write(rgba: card(width, height, content), width: width, height: height, neutral: neutral,
                                          make: "Nikon", model: "Z f", encoding: .lossyJPEG(quality: 0.9), to: url)
                let type = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? } ?? "?"
                let filter = CIRAWFilter(imageURL: url)
                print("SMARTPREVIEW LOSSY \(width)x\(height) \(content): \(try Data(contentsOf: url).count) bytes, type \(type), as shot \(filter.map { "\(Int($0.neutralTemperature)) K" } ?? "nil"), output \(filter?.outputImage?.extent.debugDescription ?? "nil")")
            }
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let linear = CGColorSpace(name: CGColorSpace.linearITUR_2020)!
        let (width, height) = (2560, 1706)
        let pixels = card(width, height, "noisy")
        for (name, encoding, balanced) in [("lossless", SmartPreviewDNG.Encoding.lossless16, false),
                                           ("lossy", .lossyJPEG(quality: 0.9), false),
                                           ("lossy balanced", .lossyJPEG(quality: 0.9), true)] {
            let url = folder.appendingPathComponent("big-\(name).dng")
            try SmartPreviewDNG.write(rgba: pixels, width: width, height: height, neutral: neutral,
                                      make: "Nikon", model: "Z f", encoding: encoding, balancedCamera: balanced, to: url)
            for temperature in [Float?.none, 3000, 4000, 8000] {
                guard let filter = CIRAWFilter(imageURL: url) else { print("SMARTPREVIEW BIGCARD \(name): nil"); break }
                filter.boostAmount = 0
                if let temperature { filter.neutralTemperature = temperature }
                guard let image = filter.outputImage else { print("SMARTPREVIEW BIGCARD \(name): no output"); break }
                let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
                var pixel = [Float](repeating: 0, count: 4)
                context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: average.extent,
                               format: .RGBAf, colorSpace: linear)
                print(String(format: "SMARTPREVIEW BIGCARD %@ at %@: %.4f/%.4f/%.4f", name, temperature.map { "\(Int($0))K" } ?? "as shot",
                             pixel[0], pixel[1], pixel[2]))
            }
        }
    }

    /// The real comparison, on a Mac with sample RAWs.
    func testSmartPreviewsAgainstTheRAW() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["ATELIER_SAMPLE_RAWS"] else { throw XCTSkip("Set ATELIER_SAMPLE_RAWS") }
        let out = URL(fileURLWithPath: environment["ATELIER_SAMPLE_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let raws = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { ["nef", "cr3", "arw", "raf", "dng"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(4)
        let context = CIContext(options: [.cacheIntermediates: false])
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        func render(_ url: URL, temperature: Double?, tint: Double?, exposure: Float, edge: CGFloat?,
                    matrix: [Double]? = nil) -> (CGImage, TimeInterval)? {
            let start = Date()
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            if let edge {
                let native = max(filter.nativeSize.width, filter.nativeSize.height)
                if native > edge { filter.scaleFactor = Float(edge / native) }
            }
            if let matrix {
                // White balance outside the RAW engine: the DNG stays at as shot and the RAW's own
                // change of white is applied as a 3×3 in the engine's linear stage.
                let m = matrix.map { CGFloat($0) }
                let color = CIFilter.colorMatrix()
                color.rVector = CIVector(x: m[0], y: m[1], z: m[2], w: 0)
                color.gVector = CIVector(x: m[3], y: m[4], z: m[5], w: 0)
                color.bVector = CIVector(x: m[6], y: m[7], z: m[8], w: 0)
                color.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
                color.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
                filter.linearSpaceFilter = color
            } else {
                if let temperature { filter.neutralTemperature = Float(temperature) }
                if let tint { filter.neutralTint = Float(tint) }
            }
            filter.exposure = exposure
            guard let image = filter.outputImage,
                  let cg = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: srgb) else { return nil }
            return (cg, Date().timeIntervalSince(start))
        }

        /// Mean absolute difference per channel (0-255) of two images, the smaller scaled to fit.
        func difference(_ a: CGImage, _ b: CGImage) -> [Double] {
            let width = min(a.width, b.width), height = min(a.height, b.height)
            func pixels(_ image: CGImage) -> [UInt8] {
                var data = [UInt8](repeating: 0, count: width * height * 4)
                let bitmap = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                       space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                bitmap.interpolationQuality = .high
                bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return data
            }
            let pa = pixels(a), pb = pixels(b)
            var sums = [0.0, 0.0, 0.0]
            for i in stride(from: 0, to: pa.count, by: 4) {
                for c in 0..<3 { sums[c] += abs(Double(pa[i + c]) - Double(pb[i + c])) }
            }
            return sums.map { $0 / Double(width * height) }
        }

        /// The RAW's linear Rec. 2020 pixels, small, without tone curve or boosts.
        let linear = CGColorSpace(name: CGColorSpace.linearITUR_2020)!
        func linearPixels(_ url: URL, temperature: Double, tint: Double) -> [Float]? {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            let native = max(filter.nativeSize.width, filter.nativeSize.height)
            filter.scaleFactor = Float(384 / native)
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
            if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
            filter.neutralTemperature = Float(temperature)
            filter.neutralTint = Float(tint)
            guard let image = filter.outputImage else { return nil }
            let extent = image.extent.integral
            var pixels = [Float](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
            context.render(image, toBitmap: &pixels, rowBytes: Int(extent.width) * 16, bounds: extent, format: .RGBAf, colorSpace: linear)
            return pixels
        }
        /// The 3×3 that takes the RAW at as shot to the RAW at (temperature, tint), by least squares
        /// over unclipped pixels: what a change of white does to this camera's photos.
        func whiteMatrix(_ url: URL, from shot: (temperature: Double, tint: Double), to temperature: Double, _ tint: Double) -> [Double]? {
            guard let a = linearPixels(url, temperature: shot.temperature, tint: shot.tint),
                  let b = linearPixels(url, temperature: temperature, tint: tint), a.count == b.count else { return nil }
            var xx = [Double](repeating: 0, count: 9), yx = [Double](repeating: 0, count: 9)
            for i in stride(from: 0, to: a.count, by: 4) {
                let x = (0..<3).map { Double(a[i + $0]) }, y = (0..<3).map { Double(b[i + $0]) }
                guard x.allSatisfy({ $0 > 0.002 && $0 < 0.9 }), y.allSatisfy({ $0 > 0.002 && $0 < 0.9 }) else { continue }
                for r in 0..<3 { for c in 0..<3 { xx[r * 3 + c] += x[r] * x[c]; yx[r * 3 + c] += y[r] * x[c] } }
            }
            // A = YXᵀ (XXᵀ)⁻¹
            let m = xx
            let det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
            guard abs(det) > 1e-12 else { return nil }
            // Split up so the type checker finishes in time.
            let c00: Double = m[4] * m[8] - m[5] * m[7]
            let c01: Double = -(m[1] * m[8] - m[2] * m[7])
            let c02: Double = m[1] * m[5] - m[2] * m[4]
            let c10: Double = -(m[3] * m[8] - m[5] * m[6])
            let c11: Double = m[0] * m[8] - m[2] * m[6]
            let c12: Double = -(m[0] * m[5] - m[2] * m[3])
            let c20: Double = m[3] * m[7] - m[4] * m[6]
            let c21: Double = -(m[0] * m[7] - m[1] * m[6])
            let c22: Double = m[0] * m[4] - m[1] * m[3]
            let inv: [Double] = [c00, c01, c02, c10, c11, c12, c20, c21, c22].map { $0 / det }
            var product = [Double](repeating: 0, count: 9)
            for k in 0..<9 {
                let row = k / 3, column = k % 3
                var sum = 0.0
                for j in 0..<3 { sum += yx[row * 3 + j] * inv[j * 3 + column] }
                product[k] = sum
            }
            return product
        }

        for raw in raws {
            let base = raw.deletingPathExtension().lastPathComponent
            for (name, encoding, balanced) in [("lossless", SmartPreviewDNG.Encoding.lossless16, false),
                                               ("lossy90", .lossyJPEG(quality: 0.9), false),
                                               ("lossy90b", .lossyJPEG(quality: 0.9), true),
                                               ("lossy75b", .lossyJPEG(quality: 0.75), true),
                                               ("lossy90b+matrix", .lossyJPEG(quality: 0.9), true)] {
                let dng = out.appendingPathComponent("\(base)-\(name).dng")
                let started = Date()
                let shot = try SmartPreviewDNG.make(from: raw, to: dng, encoding: encoding, balancedCamera: balanced, context: context)
                let made = Date().timeIntervalSince(started)
                let size = try Data(contentsOf: dng).count
                if let opened = CIRAWFilter(imageURL: dng) {
                    print(String(format: "SMARTPREVIEW %@ %@: RAW as shot %.0f K tint %.1f; DNG reports %.0f K tint %.1f, baseline %.2f",
                                 base, name, shot.temperature, shot.tint, opened.neutralTemperature, opened.neutralTint, opened.baselineExposure))
                }
                guard CIRAWFilter(imageURL: dng) != nil else {
                    print("SMARTPREVIEW \(base) \(name): \(size) bytes, made in \(Int(made * 1000)) ms, CIRAWFilter can't open it")
                    continue
                }
                for (label, temperature, tint, exposure) in [("as shot", shot.temperature, shot.tint, Float(0)),
                                                             ("4000K", 4000, shot.tint, 0), ("7500K", 7500, shot.tint, 0),
                                                             ("tint+30", shot.temperature, shot.tint + 30, 0),
                                                             ("+1 EV", shot.temperature, shot.tint, 1), ("-1 EV", shot.temperature, shot.tint, -1)] {
                    var matrix: [Double]?
                    if name.hasSuffix("+matrix"), temperature != shot.temperature || tint != shot.tint {
                        let started = Date()
                        matrix = whiteMatrix(raw, from: shot, to: temperature, tint)
                        print("SMARTPREVIEW \(base) \(name) \(label): matrix \(matrix?.map { String(format: "%.3f", $0) }.joined(separator: " ") ?? "nil") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                    }
                    guard let original = render(raw, temperature: temperature, tint: tint, exposure: exposure, edge: 2560),
                          let preview = render(dng, temperature: temperature, tint: tint, exposure: exposure, edge: nil, matrix: matrix) else {
                        print("SMARTPREVIEW \(base) \(name) \(label): render failed")
                        continue
                    }
                    let diff = difference(original.0, preview.0).map { String(format: "%.1f", $0) }.joined(separator: "/")
                    print("SMARTPREVIEW \(base) \(name) \(label): \(size / 1024) KB, made \(Int(made * 1000)) ms, RAW render \(Int(original.1 * 1000)) ms, preview render \(Int(preview.1 * 1000)) ms, mean |diff| RGB \(diff)")
                    if label == "as shot" || label == "4000K" {
                        for (suffix, image) in [("raw", original.0), ("preview", preview.0)] {
                            let png = out.appendingPathComponent("\(base)-\(name)-\(label.replacingOccurrences(of: " ", with: ""))-\(suffix).png")
                            if let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) {
                                CGImageDestinationAddImage(destination, image, nil)
                                CGImageDestinationFinalize(destination)
                            }
                        }
                    }
                }
            }
        }
    }
}
