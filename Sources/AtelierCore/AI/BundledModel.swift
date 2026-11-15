import CoreML
import Foundation

/// A Core ML model built into the app (a `.mlpackage` in AtelierCore's `Models` resources). It is
/// compiled once into Caches/Atelier/Models (a fraction of a second) and loaded on first use, from
/// any thread. Select People's parts model and Cull's face landmarker both load this way.
public final class BundledModel: @unchecked Sendable {
    /// The package's name, without `.mlpackage`.
    public let name: String
    /// The converted model's source (first 12 hex digits of the original file's SHA-256), so a
    /// new model compiles into a new cache folder.
    public let version: String

    private let lock = NSLock()
    private var loaded: MLModel?
    private var tried = false
    private var loadFailure: String?

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    /// Whether the model is in the app and loads (loading it the first time).
    public var isAvailable: Bool { model() != nil }

    /// Whether the model loaded, without loading it: nil until something first asked for it, so
    /// a view can show it without waiting.
    public var loadedState: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return tried ? loaded != nil : nil
    }

    /// Why the model didn't load, for a panel and the log; nil when it loaded or hasn't been tried.
    public var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return loadFailure
    }

    /// The loaded model, or nil when it isn't in the app or fails to load.
    public func model() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if tried { return loaded }
        tried = true
        do {
            loaded = try load()
        } catch {
            loadFailure = "\(error)"
            NSLog("Atelier: built-in model %@ didn't load: %@", name, "\(error)")
        }
        return loaded
    }

    /// The model package in AtelierCore's resource bundle: beside the app's executable or in its
    /// Resources folder (packaged app), or SwiftPM's own bundle (tests, Xcode runs).
    public func packageURL() -> URL? { Self.resourceURL(name: name, extension: "mlpackage") }

    /// A file in AtelierCore's `Models` resources (an `.mlpackage`, or AI Denoise's `.onnx`),
    /// wherever the resource bundle is.
    public static func resourceURL(name: String, extension ext: String) -> URL? {
        let bundleName = "Atelier_AtelierCore.bundle"
        let folders = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                       Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for folder in folders {
            if let bundle = Bundle(url: folder.appendingPathComponent(bundleName)),
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Models") {
                return url
            }
        }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Models")
    }

    struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    private func load() throws -> MLModel {
        guard let source = packageURL() else { throw LoadError(description: "\(name).mlpackage isn't in the app's resources") }
        let files = FileManager.default
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw LoadError(description: "no Caches folder")
        }
        let folder = caches.appendingPathComponent("Atelier/Models", isDirectory: true)
        let compiled = folder.appendingPathComponent("\(name)-\(version).mlmodelc", isDirectory: true)
        if !files.fileExists(atPath: compiled.path) {
            let temporary = try MLModel.compileModel(at: source)
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? files.moveItem(at: temporary, to: compiled)) == nil {
                return try MLModel(contentsOf: temporary, configuration: configuration)
            }
        }
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// An output's values as Floats in memory order of a packed array, whatever its element type
    /// and strides (Float16 outputs included).
    public static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        func read(_ element: (Int) -> Float) {
            for index in 0..<count {
                var rest = index, offset = 0
                for axis in stride(from: shape.count - 1, through: 0, by: -1) {
                    offset += (rest % shape[axis]) * strides[axis]
                    rest /= shape[axis]
                }
                out[index] = element(offset)
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
            #if arch(arm64)
            if array.dataType == .float16 {
                let p = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
                read { Float(p[$0]) }
                return out
            }
            #endif
            // Anything else (Float16 on Intel): slower, by index, but works on every Mac.
            for index in 0..<count {
                var rest = index
                var indices = [NSNumber](repeating: 0, count: shape.count)
                for axis in stride(from: shape.count - 1, through: 0, by: -1) {
                    indices[axis] = NSNumber(value: rest % shape[axis])
                    rest /= shape[axis]
                }
                out[index] = array[indices].floatValue
            }
        }
        return out
    }
}
