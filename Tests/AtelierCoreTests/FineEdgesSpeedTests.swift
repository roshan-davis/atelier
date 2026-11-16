import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AtelierCore

/// How fast Fine Edges runs with different ONNX Runtime settings, and whether each gives the same
/// matte as the CPU. Opt-in, one setting per run (a Core ML attempt can crash the process):
/// `ATELIER_FINE_EDGES_BENCH=<variant> ATELIER_FINE_EDGES_PHOTO=/path/photo swift test --filter
/// FineEdgesSpeedTests`. Variants: cpu, cpu-threads-<n>, coreml-mlprogram-all,
/// coreml-neuralnetwork-all, coreml-mlprogram-cpugpu, coreml-neuralnetwork-cpugpu. The CPU's
/// matte is kept in the temporary folder for the others to compare with.
final class FineEdgesSpeedTests: XCTestCase {
    func testOneSetting() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let variant = environment["ATELIER_FINE_EDGES_BENCH"], let photo = environment["ATELIER_FINE_EDGES_PHOTO"] else {
            throw XCTSkip("Set ATELIER_FINE_EDGES_BENCH and ATELIER_FINE_EDGES_PHOTO to run")
        }
        let model = try XCTUnwrap(FineEdges.active, "Fine Edges isn't downloaded")
        let image = try XCTUnwrap(Self.thumbnail(photo, size: model.size))
        FineEdges.prefersCoreML = variant.hasPrefix("coreml")
        FineEdges.intraOpThreads = variant.hasPrefix("cpu-threads-") ? Int(variant.dropFirst("cpu-threads-".count)) : nil
        if variant.hasPrefix("coreml") {
            let format = variant.contains("neuralnetwork") ? "NeuralNetwork" : "MLProgram"
            let units = variant.hasSuffix("cpugpu") ? "CPUAndGPU" : "ALL"
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("FineEdgesBench-\(format)-\(units)")
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            FineEdges.coreMLOptionsOverride = ["ModelFormat": format, "MLComputeUnits": units, "ModelCacheDirectory": cache.path]
        }
        FineEdges.forgetSession()
        defer {
            FineEdges.prefersCoreML = false
            FineEdges.intraOpThreads = nil
            FineEdges.coreMLOptionsOverride = nil
            FineEdges.forgetSession()
        }
        var times: [Double] = []
        var matte: [Float]?
        for _ in 0..<2 {
            let started = Date()
            matte = FineEdges.matte(of: image, model: model)
            times.append(Date().timeIntervalSince(started))
        }
        let values = try XCTUnwrap(matte, "\(variant): no matte (\(FineEdges.failure ?? "no reason"))")
        let reference = FileManager.default.temporaryDirectory.appendingPathComponent("FineEdgesBench-cpu.matte")
        var difference = "–"
        if variant == "cpu" {
            try values.withUnsafeBufferPointer { try Data(buffer: $0).write(to: reference) }
        } else if let data = try? Data(contentsOf: reference), data.count == values.count * 4 {
            let cpu = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            difference = String(format: "%.5f (1/255 = 0.00392)", zip(values, cpu).map { abs($0 - $1) }.max() ?? 0)
        }
        print("FINEBENCH: \(variant) (\(model.name)): first \(String(format: "%.1f", times[0])) s, second "
            + "\(String(format: "%.1f", times[1])) s; \(FineEdges.lastRun ?? ""); max difference from the CPU \(difference)")
    }

    private static func thumbnail(_ path: String, size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}
