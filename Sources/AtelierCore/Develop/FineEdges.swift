import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OnnxRuntimeBindings
import UniformTypeIdentifiers

/// Fine Edges: BiRefNet HR-matting (Zheng Peng et al., MIT License), in the ONNX export by Pink
/// Pixel on Hugging Face (MIT), an optional download (about 470 MB) from Settings > AI or the
/// mask panel. A matting model: it gives every pixel how much of it is foreground, at
/// 2048 × 2048, so single strands of hair come through partly see-through (Rosh, Nov 11, 2026:
/// BiRefNet lite's cut-out at 1024 missed loose strands);
/// Select Subject, Select Object and Select People use it to redraw their edges. It runs on this
/// Mac with Microsoft's ONNX Runtime (MIT), built into the app, which hands what it can to Core ML.
public enum FineEdges {
    public static let modelName = "BiRefNet HR matting"
    /// The file Atelier downloads, pinned to its SHA-256 so a changed file is refused.
    public static let downloadURL =
        // Pinned to the repository revision as well as the checksum.
        URL(string: "https://huggingface.co/PinkPixel/birefnet-hr-matting-onnx/resolve/792518b9d4dfe9793891712677de25e554f948c6/model_fp16.onnx")!
    public static let sha256 = "c0216070c15542b7197bcf13eb3ea07af0fc5595c591037b7c9766c3cc6470f0"
    /// About how much is downloaded, for the buttons.
    public static let downloadSize = "470 MB"
    /// The model's square input size.
    public static let size = 2048

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
            .appendingPathComponent("BiRefNet-HR-matting-\(sha256.prefix(12)).onnx")
    }

    /// Where Core ML keeps its compiled copy of the model (rebuilt if deleted).
    static var coreMLCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Atelier/Models/FineEdges-CoreML-\(sha256.prefix(12))", isDirectory: true)
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
        removeOldModels()
    }

    /// Deletes earlier Fine Edges models (the 115 MB BiRefNet lite of the first test build), so
    /// a switch of model doesn't leave hundreds of MB behind.
    static func removeOldModels() {
        let folder = modelURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("BiRefNet-") && file != modelURL {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes the downloaded model.
    public static func remove() throws {
        forgetSession()
        removeOldModels()
        try? FileManager.default.removeItem(at: coreMLCacheURL)
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
    /// What the last run found, for the mask panel: its time and how much of the photo it saw as
    /// foreground, or nil before a run.
    nonisolated(unsafe) public private(set) static var lastRun: String?
    nonisolated(unsafe) private static var usesCoreML = true
    /// Posted on the main queue whenever `failure` or `lastRun` changes.
    public static let statusChanged = Notification.Name("AtelierFineEdgesStatusChanged")
    /// Posted on the main queue when a matte found in the background is ready, so the editor
    /// renders again with it.
    public static let matteReady = Notification.Name("AtelierFineEdgesMatteReady")

    private static func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: statusChanged, object: nil) }
    }

    private static func forgetSession() {
        lock.lock()
        session = nil
        failure = nil
        lastRun = nil
        lock.unlock()
        announce()
    }

    /// The loaded model; Core ML runs what it can (ML Program, Neural Engine and GPU), ONNX
    /// Runtime's CPU code the rest. Call with the lock held.
    private static func loadedSession() throws -> ORTSession {
        if let session { return session }
        guard isInstalled else { throw Failure.noModel }
        let env = try environment ?? ORTEnv(loggingLevel: .warning)
        environment = env
        func options(coreML: Bool) throws -> ORTSessionOptions {
            let options = try ORTSessionOptions()
            try options.setGraphOptimizationLevel(.all)
            // Core ML compiles the model once and keeps it here; without a cache it compiles it
            // again every launch, which takes most of the first run's time.
            let cache = coreMLCacheURL
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            if coreML, (try? options.appendCoreMLExecutionProvider(withOptionsV2: ["ModelFormat": "MLProgram",
                                                                                  "MLComputeUnits": "All",
                                                                                  "ModelCacheDirectory": cache.path])) == nil {
                NSLog("Atelier: Fine Edges runs without Core ML")
                usesCoreML = false
            }
            return options
        }
        let made: ORTSession
        usesCoreML = true
        do {
            made = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options(coreML: true))
        } catch {
            // Core ML can refuse a model this large; ONNX Runtime's own CPU code still runs it.
            NSLog("Atelier: Fine Edges with Core ML failed (%@), using the CPU", "\(error)")
            usesCoreML = false
            made = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options(coreML: false))
        }
        session = made
        return made
    }

    /// The foreground matte of `image` (any size: it is stretched to `size` × `size` for the model),
    /// 0...1, `size` × `size`, rows from the top. Nil when the model isn't downloaded or fails
    /// (`failure` says why).
    public static func matte(of image: CGImage) -> [Float]? {
        guard let pixels = rgba(image) else { return nil }
        lock.lock()
        defer { lock.unlock(); announce() }
        lastRun = "Fine Edges is working… (the first time after a download takes longest)"
        failure = nil
        announce()
        let started = Date()
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
            let raw: [Float]
            if data.count == size * size * 4 {
                raw = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else if data.count == size * size * 2 {
                raw = data.withUnsafeBytes { $0.bindMemory(to: UInt16.self).map(floatFromHalf) }
            } else {
                throw Failure.run("unexpected output size \(data.count) bytes")
            }
            let chances = probabilities(raw)
            saveDiagnostics(input: image, matte: chances)
            let foreground = Double(chances.lazy.filter { $0 > 0.5 }.count) / Double(max(1, chances.count))
            let seconds = Date().timeIntervalSince(started)
            failure = nil
            lastRun = String(format: "Fine Edges ran in %.1f s (%@); %.0f%% of the photo is foreground", seconds,
                             usesCoreML ? "Core ML" : "CPU", foreground * 100)
            NSLog("Atelier: %@ (outputs %@, input %@)", lastRun ?? "", try session.outputNames().joined(separator: ", "),
                  inputName)
            return chances
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

    /// BiRefNet's input: 1 × 3 × `size` × `size`, RGB planes, scaled to 0...1 and normalized with
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

    /// Where the last run's input and matte are saved as PNGs, so what the model saw and found
    /// can be looked at (Settings > AI > Masking Models > Show Last Result).
    public static var diagnosticsFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Atelier/Fine Edges Last Run", isDirectory: true)
    }

    static func saveDiagnostics(input: CGImage, matte: [Float]) {
        let folder = diagnosticsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ image: CGImage?, _ name: String) {
            guard let image, let destination = CGImageDestinationCreateWithURL(
                folder.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        write(input, "1 What the model saw.png")
        write(PeopleSkin.grayImage(matte, width: size, height: size), "2 What it found (white = selected).png")
    }

    /// An IEEE half-precision float's bits as a Float (works on Intel too).
    static func floatFromHalf(_ bits: UInt16) -> Float {
        let sign: UInt32 = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1f), fraction = UInt32(bits & 0x3ff)
        if exponent == 0 {
            let value = Float(fraction) * Float(pow(2.0, -24.0))
            return sign == 0 ? value : -value
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7f80_0000 | (fraction << 13)) }
        return Float(bitPattern: sign | (UInt32(exponent - 15 + 127) << 23) | (fraction << 13))
    }

    /// The model gives logits; 0...1 output is passed through as is.
    static func probabilities(_ raw: [Float]) -> [Float] {
        guard let low = raw.min(), let high = raw.max(), low < -0.001 || high > 1.001 else { return raw }
        return raw.map { 1 / (1 + exp(-$0)) }
    }
}
