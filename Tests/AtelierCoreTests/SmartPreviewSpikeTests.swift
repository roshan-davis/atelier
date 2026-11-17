import CoreImage
import Foundation
import XCTest
@testable import AtelierCore

/// AT-079d feasibility: the DNG container is valid everywhere; on a Mac with sample RAWs
/// (`ATELIER_SAMPLE_RAWS`, output to `ATELIER_SAMPLE_OUT`) each RAW is written as a lossless and
/// a lossy smart preview, both are opened with CIRAWFilter, and their renders at several white
/// balances and exposures are compared with the RAW's own at the same size.
final class SmartPreviewSpikeTests: XCTestCase {
    func testWhiteFollowsTemperature() {
        let d65 = SmartPreviewDNG.neutral(temperature: 6504, tint: 0)
        XCTAssertEqual(d65.x, 1, accuracy: 0.03)
        XCTAssertEqual(d65.y, 1, accuracy: 0.03)
        XCTAssertEqual(d65.z, 1, accuracy: 0.03)
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

        func render(_ url: URL, temperature: Double?, tint: Double?, exposure: Float, edge: CGFloat?) -> (CGImage, TimeInterval)? {
            let start = Date()
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            if let edge {
                let native = max(filter.nativeSize.width, filter.nativeSize.height)
                if native > edge { filter.scaleFactor = Float(edge / native) }
            }
            if let temperature { filter.neutralTemperature = Float(temperature) }
            if let tint { filter.neutralTint = Float(tint) }
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

        for raw in raws {
            let base = raw.deletingPathExtension().lastPathComponent
            for (name, encoding) in [("lossless", SmartPreviewDNG.Encoding.lossless16), ("lossy90", .lossyJPEG(quality: 0.9)),
                                     ("lossy75", .lossyJPEG(quality: 0.75))] {
                let dng = out.appendingPathComponent("\(base)-\(name).dng")
                let started = Date()
                let shot = try SmartPreviewDNG.make(from: raw, to: dng, encoding: encoding, context: context)
                let made = Date().timeIntervalSince(started)
                let size = try Data(contentsOf: dng).count
                guard CIRAWFilter(imageURL: dng) != nil else {
                    print("SMARTPREVIEW \(base) \(name): \(size) bytes, made in \(Int(made * 1000)) ms, CIRAWFilter can't open it")
                    continue
                }
                for (label, temperature, tint, exposure) in [("as shot", shot.temperature, shot.tint, Float(0)),
                                                             ("4000K", 4000, shot.tint, 0), ("7500K", 7500, shot.tint, 0),
                                                             ("tint+30", shot.temperature, shot.tint + 30, 0),
                                                             ("+1 EV", shot.temperature, shot.tint, 1), ("-1 EV", shot.temperature, shot.tint, -1)] {
                    guard let original = render(raw, temperature: temperature, tint: tint, exposure: exposure, edge: 2560),
                          let preview = render(dng, temperature: temperature, tint: tint, exposure: exposure, edge: nil) else {
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
