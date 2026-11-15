import CoreGraphics
import Foundation
import ImageIO
import OnnxRuntimeBindings
import UniformTypeIdentifiers

/// Fine Edges: BiRefNet (Zheng Peng et al., MIT License) redraws the edges of Select Subject,
/// Select Object and Select People. Two optional downloads from Settings > AI or the mask panel,
/// either or both, and you choose which one runs (Rosh, Nov 11, 2026):
/// - Fast: BiRefNet lite (onnx-community's ONNX export, MIT), 115 MB, a cut-out at 1024 × 1024,
///   a few seconds with Core ML.
/// - Hair Detail: BiRefNet HR matting (Pink Pixel's ONNX export, MIT), 470 MB, a matte at
///   2048 × 2048 that gives single strands partly see-through; Core ML refuses it, so it runs on
///   the CPU in about half a minute.
/// Both run on this Mac with Microsoft's ONNX Runtime (MIT), built into the app.
public enum FineEdges {
    public enum Model: String, CaseIterable, Identifiable, Sendable {
        case fast, hairDetail

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .fast: return "Fast"
            case .hairDetail: return "Hair Detail"
            }
        }

        /// What it is and how it behaves, for Settings and help tags.
        public var detail: String {
            switch self {
            case .fast: return "BiRefNet lite: a few seconds; clean outlines, misses loose strands"
            case .hairDetail: return "BiRefNet HR matting: about 30 seconds; finer hair, see-through strands"
            }
        }

        /// The file Atelier downloads, pinned to its SHA-256 so a changed file is refused.
        public var downloadURL: URL {
            switch self {
            case .fast:
                return URL(string: "https://huggingface.co/onnx-community/BiRefNet_lite-ONNX/resolve/main/onnx/model_fp16.onnx")!
            case .hairDetail:
                // Pinned to the repository revision as well as the checksum.
                return URL(string: "https://huggingface.co/PinkPixel/birefnet-hr-matting-onnx/resolve/792518b9d4dfe9793891712677de25e554f948c6/model_fp16.onnx")!
            }
        }

        public var sha256: String {
            switch self {
            case .fast: return "d39b897ceb16ae654c1731f3dba0cf9b368d9cae74b5a57459b455cc8bfec402"
            case .hairDetail: return "c0216070c15542b7197bcf13eb3ea07af0fc5595c591037b7c9766c3cc6470f0"
            }
        }

        /// About how much is downloaded, for the buttons.
        public var downloadSize: String {
            switch self {
            case .fast: return "115 MB"
            case .hairDetail: return "470 MB"
            }
        }

        /// The model's square input size.
        public var size: Int {
            switch self {
            case .fast: return 1024
            case .hairDetail: return 2048
            }
        }

        /// Where the model lives: Application Support/Atelier/Models, named by its checksum so a
        /// new file is a new name.
        public var modelURL: URL {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let stem = self == .fast ? "BiRefNet-lite" : "BiRefNet-HR-matting"
            return support.appendingPathComponent("Atelier/Models", isDirectory: true)
                .appendingPathComponent("\(stem)-\(sha256.prefix(12)).onnx")
        }

        /// Where Core ML keeps its compiled copy of the model (rebuilt if deleted).
        var coreMLCacheURL: URL {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return caches.appendingPathComponent("Atelier/Models/FineEdges-CoreML-\(sha256.prefix(12))",
                                                 isDirectory: true)
        }

        public var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    }

    private static let chosenKey = "fineEdges.model"

    /// The model you picked in Settings > AI or the mask panel. Downloading a model picks it.
    public static var chosen: Model {
        get { UserDefaults.standard.string(forKey: chosenKey).flatMap(Model.init(rawValue:)) ?? .fast }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: chosenKey)
            modelsChanged()
        }
    }

    /// The model Fine Edges runs: the chosen one if it is downloaded, otherwise the other one;
    /// nil when neither is.
    public static var active: Model? {
        let picked = chosen
        if picked.isInstalled { return picked }
        return Model.allCases.first { $0.isInstalled }
    }

    /// Whether either model is downloaded.
    public static var isInstalled: Bool { active != nil }

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

    // MARK: Download

    /// Downloads `model`, checks it, puts it in place and picks it. `progress` gets 0...1 on any
    /// thread.
    public static func install(_ model: Model, progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await ModelDownload.fetch(model.downloadURL, sha256: model.sha256, to: model.modelURL, progress: progress)
        } catch is ModelDownload.ChecksumMismatch {
            throw Failure.checksum
        }
        forgetSession()
        removeOldModels()
        chosen = model
    }

    /// Tells the panels and the editor that which model runs may have changed, so they show it
    /// and render again.
    private static func modelsChanged() {
        announce()
        DispatchQueue.main.async { NotificationCenter.default.post(name: matteReady, object: nil) }
    }

    /// Deletes Fine Edges files that are neither model's current file (an earlier download of a
    /// changed model), so they don't leave hundreds of MB behind.
    static func removeOldModels() {
        let kept = Set(Model.allCases.map { $0.modelURL.lastPathComponent })
        let folder = Model.fast.modelURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("BiRefNet-") && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes a downloaded model and its Core ML copy.
    public static func remove(_ model: Model) throws {
        forgetSession()
        removeOldModels()
        try? FileManager.default.removeItem(at: model.coreMLCacheURL)
        if model.isInstalled { try FileManager.default.removeItem(at: model.modelURL) }
        modelsChanged()
    }

    /// The file's SHA-256, lowercase hex.
    static func checksum(of url: URL) throws -> String { try ModelDownload.checksum(of: url) }

    // MARK: Running

    private static let lock = NSLock()
    nonisolated(unsafe) private static var environment: ORTEnv?
    /// The loaded model (one at a time: Hair Detail alone takes about 1 GB in memory).
    nonisolated(unsafe) private static var session: (model: Model, session: ORTSession)?
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

    /// `model`, loaded; Core ML runs what it can (ML Program, Neural Engine and GPU), ONNX
    /// Runtime's CPU code the rest. Call with the lock held.
    private static func loadedSession(_ model: Model) throws -> ORTSession {
        if let session, session.model == model { return session.session }
        session = nil
        guard model.isInstalled else { throw Failure.noModel }
        let modelURL = model.modelURL
        let env = try environment ?? ORTEnv(loggingLevel: .warning)
        environment = env
        func options(coreML: Bool) throws -> ORTSessionOptions {
            let options = try ORTSessionOptions()
            try options.setGraphOptimizationLevel(.all)
            // Core ML compiles the model once and keeps it here; without a cache it compiles it
            // again every launch, which takes most of the first run's time.
            let cache = model.coreMLCacheURL
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
        session = (model, made)
        return made
    }

    /// `model`'s foreground matte of `image` (any size: it is stretched to the model's square),
    /// 0...1, `model.size` × `model.size`, rows from the top. Nil when the model isn't downloaded
    /// or fails (`failure` says why).
    public static func matte(of image: CGImage, model: Model) -> [Float]? {
        let size = model.size
        guard let pixels = rgba(image, size: size) else { return nil }
        lock.lock()
        defer { lock.unlock(); announce() }
        lastRun = "Fine Edges (\(model.name)) is working… (the first time after a download takes longest)"
        failure = nil
        announce()
        let started = Date()
        do {
            let session = try loadedSession(model)
            let input = NSMutableData(data: inputTensor(pixels, size: size).withUnsafeBufferPointer { Data(buffer: $0) })
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
            saveDiagnostics(input: image, matte: chances, size: size)
            let foreground = Double(chances.lazy.filter { $0 > 0.5 }.count) / Double(max(1, chances.count))
            let seconds = Date().timeIntervalSince(started)
            failure = nil
            lastRun = String(format: "Fine Edges (%@) ran in %.1f s (%@); %.0f%% of the photo is foreground",
                             model.name, seconds, usesCoreML ? "Core ML" : "CPU", foreground * 100)
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
    static func rgba(_ image: CGImage, size: Int) -> [UInt8]? {
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
    static func inputTensor(_ pixels: [UInt8], size: Int) -> [Float] {
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

    static func saveDiagnostics(input: CGImage, matte: [Float], size: Int) {
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
