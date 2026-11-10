import CoreGraphics
import CryptoKit
import Foundation
import OnnxRuntimeBindings

/// Fine Edges: BiRefNet (Zheng Peng et al., MIT License), the lite model as published in ONNX by
/// onnx-community on Hugging Face, an optional download (about 115 MB) from Settings > AI or the
/// mask panel. It finds the photo's foreground at 1024 × 1024 with edges down to single hairs;
/// Select Subject, Select Object and Select People use it to redraw their edges. It runs on this
/// Mac with Microsoft's ONNX Runtime (MIT), built into the app, which hands what it can to Core ML.
public enum FineEdges {
    public static let modelName = "BiRefNet lite"
    /// The file Atelier downloads, pinned to its SHA-256 so a changed file is refused.
    public static let downloadURL =
        URL(string: "https://huggingface.co/onnx-community/BiRefNet_lite-ONNX/resolve/main/onnx/model_fp16.onnx")!
    public static let sha256 = "d39b897ceb16ae654c1731f3dba0cf9b368d9cae74b5a57459b455cc8bfec402"
    /// About how much is downloaded, for the buttons ("115 MB").
    public static let downloadSize = "115 MB"
    /// The model's square input size.
    public static let size = 1024

    public enum Failure: LocalizedError {
        case checksum, noModel, run(String)

        public var errorDescription: String? {
            switch self {
            case .checksum: return "The downloaded model isn't the expected file, so it wasn't installed."
            case .noModel: return "The Fine Edges model isn't downloaded."
            case .run(let reason): return "The Fine Edges model didn't run: \(reason)"
            }
        }
    }

    /// Where the model lives: Application Support/Atelier/Models, named by its checksum so a new
    /// model is a new file.
    public static var modelURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Atelier/Models", isDirectory: true)
            .appendingPathComponent("BiRefNet-lite-\(sha256.prefix(12)).onnx")
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    // MARK: Download

    /// Downloads the model, checks it and puts it in place. `progress` gets 0...1 on any thread.
    public static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let holder = ObservationHolder()
        let downloaded: URL = try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: downloadURL) { url, response, error in
                holder.observation = nil
                if let error { return continuation.resume(throwing: error) }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return continuation.resume(throwing: URLError(.badServerResponse))
                }
                guard let url else { return continuation.resume(throwing: URLError(.cannotOpenFile)) }
                // The file is removed when this returns: move it somewhere of ours first.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".onnx")
                do {
                    try FileManager.default.moveItem(at: url, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            holder.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            holder.task = task
            task.resume()
          }
        } onCancel: {
            holder.task?.cancel()
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        guard try checksum(of: downloaded) == sha256 else { throw Failure.checksum }
        let folder = modelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: downloaded, to: modelURL)
        forgetSession()
    }

    /// Deletes the downloaded model.
    public static func remove() throws {
        forgetSession()
        if isInstalled { try FileManager.default.removeItem(at: modelURL) }
    }

    /// The file's SHA-256, lowercase hex, read in 4 MB pieces.
    static func checksum(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let piece = try handle.read(upToCount: 4 << 20), !piece.isEmpty { hash.update(data: piece) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class ObservationHolder: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask?
    }

    // MARK: Running

    private static let lock = NSLock()
    nonisolated(unsafe) private static var environment: ORTEnv?
    nonisolated(unsafe) private static var session: ORTSession?
    /// Why the model last failed to load or run, for the mask panel; nil when it worked.
    nonisolated(unsafe) public private(set) static var failure: String?

    private static func forgetSession() {
        lock.lock()
        session = nil
        failure = nil
        lock.unlock()
    }

    /// The loaded model; Core ML runs what it can (ML Program, Neural Engine and GPU), ONNX
    /// Runtime's CPU code the rest. Call with the lock held.
    private static func loadedSession() throws -> ORTSession {
        if let session { return session }
        guard isInstalled else { throw Failure.noModel }
        let env = try environment ?? ORTEnv(loggingLevel: .warning)
        environment = env
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        if (try? options.appendCoreMLExecutionProvider(withOptionsV2: ["ModelFormat": "MLProgram",
                                                                     "MLComputeUnits": "All"])) == nil {
            // Without Core ML it still runs, on the CPU.
            NSLog("Atelier: Fine Edges runs without Core ML")
        }
        let made = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        session = made
        return made
    }

    /// The foreground matte of `image` (any size: it is stretched to 1024 × 1024 for the model),
    /// 0...1, `size` × `size`, rows from the top. Nil when the model isn't downloaded or fails
    /// (`failure` says why).
    public static func matte(of image: CGImage) -> [Float]? {
        guard let pixels = rgba(image) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        do {
            let session = try loadedSession()
            let input = NSMutableData(data: inputTensor(pixels).withUnsafeBufferPointer { Data(buffer: $0) })
            let value = try ORTValue(tensorData: input, elementType: .float,
                                     shape: [1, 3, NSNumber(value: size), NSNumber(value: size)])
            guard let inputName = try session.inputNames().first,
                  let outputName = try session.outputNames().first else { throw Failure.run("no inputs or outputs") }
            let outputs = try session.run(withInputs: [inputName: value], outputNames: [outputName], runOptions: nil)
            guard let output = outputs[outputName] else { throw Failure.run("no output") }
            let data = try output.tensorData() as Data
            guard data.count == size * size * 4 else { throw Failure.run("unexpected output size \(data.count)") }
            let raw = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            failure = nil
            return probabilities(raw)
        } catch {
            failure = error.localizedDescription
            NSLog("Atelier: Fine Edges failed: %@", "\(error)")
            return nil
        }
    }

    /// The image drawn at `size` × `size`, RGBA, rows from the top.
    static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: DevelopRenderer.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return drawn ? pixels : nil
    }

    /// BiRefNet's input: 1 × 3 × 1024 × 1024, RGB planes, scaled to 0...1 and normalized with
    /// ImageNet's mean and deviation (the model's preprocessor_config.json).
    static func inputTensor(_ pixels: [UInt8]) -> [Float] {
        let mean: [Float] = [0.485, 0.456, 0.406], deviation: [Float] = [0.229, 0.224, 0.225]
        let plane = size * size
        var out = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane {
            for c in 0..<3 {
                out[c * plane + i] = (Float(pixels[i * 4 + c]) / 255 - mean[c]) / deviation[c]
            }
        }
        return out
    }

    /// The model gives logits; 0...1 output is passed through as is.
    static func probabilities(_ raw: [Float]) -> [Float] {
        guard let low = raw.min(), let high = raw.max(), low < -0.001 || high > 1.001 else { return raw }
        return raw.map { 1 / (1 + exp(-$0)) }
    }
}
