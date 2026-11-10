import CoreGraphics
import CoreML
import Foundation

/// Google's MediaPipe Multiclass Selfie Segmentation (Apache License 2.0), converted to Core ML by
/// `Scripts/models/convert_mediapipe_multiclass.py` and built into the app (Models/PeopleParts.mlpackage
/// in AtelierCore's resources, about 8 MB). For each pixel of a 256 × 256 picture of a person it
/// gives the chance of background, hair, body skin, face skin, clothes and other (accessories).
/// Select People's Face Skin, Body Skin, Hair, Clothes and Entire Person come from it; it runs on
/// this Mac with Core ML (Neural Engine and GPU on Apple Silicon, CPU and GPU on Intel).
public enum PeopleParts {
    /// The model's classes, in its output order.
    public enum Class: Int, CaseIterable, Sendable {
        case background, hair, bodySkin, faceSkin, clothes, others
    }

    /// The model's square input size.
    public static let size = 256
    /// The converted model's source (first 12 hex digits of the TFLite file's SHA-256), so a new
    /// model compiles into a new cache folder.
    static let version = "c6748b1253a9"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: MLModel?
    nonisolated(unsafe) private static var tried = false

    /// Whether the model is in the app and loads.
    public static var isAvailable: Bool { model() != nil }

    static func model() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if tried { return loaded }
        tried = true
        loaded = load()
        return loaded
    }

    /// The model package in AtelierCore's resource bundle: beside the app's executable or in its
    /// Resources folder (packaged app), or SwiftPM's own bundle (tests, Xcode runs).
    static func packageURL() -> URL? {
        let bundleName = "Atelier_AtelierCore.bundle"
        let folders = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                       Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for folder in folders {
            if let bundle = Bundle(url: folder.appendingPathComponent(bundleName)),
               let url = bundle.url(forResource: "PeopleParts", withExtension: "mlpackage", subdirectory: "Models") {
                return url
            }
        }
        return Bundle.module.url(forResource: "PeopleParts", withExtension: "mlpackage", subdirectory: "Models")
    }

    /// Compiles the package once into Caches (a fraction of a second) and loads it.
    private static func load() -> MLModel? {
        guard let source = packageURL() else { return nil }
        let files = FileManager.default
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("Atelier/Models", isDirectory: true)
        let compiled = folder.appendingPathComponent("PeopleParts-\(version).mlmodelc", isDirectory: true)
        if !files.fileExists(atPath: compiled.path) {
            guard let temporary = try? MLModel.compileModel(at: source) else { return nil }
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? files.moveItem(at: temporary, to: compiled)) == nil {
                return try? MLModel(contentsOf: temporary, configuration: configuration)
            }
        }
        return try? MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// Runs the model on `region` (pixels, top-left origin) of an RGBA image and returns one map
    /// per `Class`, each `width` × `height` with the class's chance inside the region and 0
    /// outside. Nil when the model isn't available or fails.
    public static func segment(pixels: [UInt8], width: Int, height: Int, region: CGRect) -> [[Float]]? {
        guard let model = model() else { return nil }
        let r = region.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isEmpty, r.width >= 8, r.height >= 8, pixels.count >= width * height * 4 else { return nil }
        let input = sample(pixels: pixels, width: width, height: height, region: r)
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: size), NSNumber(value: size), 3], dataType: .float32)
        else { return nil }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        input.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: input.count) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: array)]),
              let output = try? model.prediction(from: provider),
              let result = output.featureValue(for: "segmentation")?.multiArrayValue,
              let chances = values(result) else { return nil }
        return place(chances, region: r, width: width, height: height)
    }

    /// The region resampled (bilinear) to `size` × `size`, RGB 0...1, rows from the top: the
    /// model's input, 1 × 256 × 256 × 3.
    static func sample(pixels: [UInt8], width: Int, height: Int, region r: CGRect) -> [Float] {
        var out = [Float](repeating: 0, count: size * size * 3)
        for oy in 0..<size {
            let sy = Double(r.minY) + (Double(oy) + 0.5) * Double(r.height) / Double(size) - 0.5
            let y0 = min(height - 1, max(0, Int(sy.rounded(.down)))), y1 = min(height - 1, y0 + 1)
            let fy = Float(min(1, max(0, sy - Double(y0))))
            for ox in 0..<size {
                let sx = Double(r.minX) + (Double(ox) + 0.5) * Double(r.width) / Double(size) - 0.5
                let x0 = min(width - 1, max(0, Int(sx.rounded(.down)))), x1 = min(width - 1, x0 + 1)
                let fx = Float(min(1, max(0, sx - Double(x0))))
                for c in 0..<3 {
                    func p(_ x: Int, _ y: Int) -> Float { Float(pixels[(y * width + x) * 4 + c]) }
                    let top = p(x0, y0) * (1 - fx) + p(x1, y0) * fx
                    let bottom = p(x0, y1) * (1 - fx) + p(x1, y1) * fx
                    out[(oy * size + ox) * 3 + c] = (top * (1 - fy) + bottom * fy) / 255
                }
            }
        }
        return out
    }

    /// The model's output as Floats, `size` × `size` × classes, whatever its element type and strides.
    static func values(_ array: MLMultiArray) -> [Float]? {
        let classes = Class.allCases.count
        guard array.shape.count == 4, array.shape[1].intValue == size, array.shape[2].intValue == size,
              array.shape[3].intValue == classes else { return nil }
        let strides = array.strides.map(\.intValue)
        var out = [Float](repeating: 0, count: size * size * classes)
        func read(_ element: (Int) -> Float) {
            for y in 0..<size {
                for x in 0..<size {
                    for c in 0..<classes {
                        out[(y * size + x) * classes + c] = element(y * strides[1] + x * strides[2] + c * strides[3])
                    }
                }
            }
        }
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            read { p[$0] }
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            read { Float(p[$0]) }
        default:
            // Float16 and anything else: slower, but works on every Mac.
            read { index in
                var rest = index
                var indices: [NSNumber] = [0, 0, 0, 0]
                for axis in 1..<4 {
                    indices[axis] = NSNumber(value: rest / strides[axis])
                    rest %= strides[axis]
                }
                return array[indices].floatValue
            }
        }
        return out
    }

    /// Each class's chances (`size` × `size` × classes) stretched back over the region (bilinear),
    /// one full-size map per class.
    static func place(_ chances: [Float], region r: CGRect, width: Int, height: Int) -> [[Float]] {
        let classes = Class.allCases.count
        var maps = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: classes)
        let x0 = max(0, Int(r.minX)), x1 = min(width, Int(r.maxX))
        let y0 = max(0, Int(r.minY)), y1 = min(height, Int(r.maxY))
        guard x0 < x1, y0 < y1 else { return maps }
        for y in y0..<y1 {
            let v = (Double(y) + 0.5 - Double(r.minY)) * Double(size) / Double(r.height) - 0.5
            let a0 = min(size - 1, max(0, Int(v.rounded(.down)))), a1 = min(size - 1, a0 + 1)
            let fv = Float(min(1, max(0, v - Double(a0))))
            for x in x0..<x1 {
                let u = (Double(x) + 0.5 - Double(r.minX)) * Double(size) / Double(r.width) - 0.5
                let b0 = min(size - 1, max(0, Int(u.rounded(.down)))), b1 = min(size - 1, b0 + 1)
                let fu = Float(min(1, max(0, u - Double(b0))))
                for c in 0..<classes {
                    func q(_ a: Int, _ b: Int) -> Float { chances[(a * size + b) * classes + c] }
                    let top = q(a0, b0) * (1 - fu) + q(a0, b1) * fu
                    let bottom = q(a1, b0) * (1 - fu) + q(a1, b1) * fu
                    maps[c][y * width + x] = top * (1 - fv) + bottom * fv
                }
            }
        }
        return maps
    }
}
