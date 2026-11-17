import CoreGraphics
import Foundation
import os
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

        /// About how much memory one run takes, in its helper process (`ModelRunner`), in GB:
        /// the network's own working memory at its fixed input size, measured on a 48 GB Mac
        /// (Mac checks 4 to 6 of PR #157: Fast peaked at 13 to 19 GB, Hair Detail at 30 to 46 GB).
        public var memoryNeededGB: Int {
            switch self {
            case .fast: return 18
            case .hairDetail: return 40
            }
        }

        /// A note for Settings when this Mac has less memory than a run takes, else nil. Rosh
        /// (Nov 16, 2026): every Mac is offered both models, with a warning where memory is short.
        public func memoryWarning(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String? {
            let installedGB = Int((Double(physicalMemory) / 1_073_741_824).rounded())
            guard installedGB < memoryNeededGB else { return nil }
            return "Needs about \(memoryNeededGB) GB of memory while it runs; this Mac has \(installedGB) GB, "
                + "so it may run slowly, and if memory runs out it stops with a message."
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
        FineMatteCache.shared.removeAll()
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

    /// Guards the status below (the run itself is serialized by `ModelRunner.fineEdges`, in its
    /// own helper process, so nothing here is held while a model runs: AT-076 C1).
    private static let lock = NSLock()
    /// Why the model last failed to load or run, for the mask panel; nil when it worked.
    nonisolated(unsafe) public private(set) static var failure: String?
    /// What the last run found, for the mask panel: its time and how much of the photo it saw as
    /// foreground, or nil before a run.
    nonisolated(unsafe) public private(set) static var lastRun: String?
    /// A matte is being found now (Lens Blur's progress line); `statusChanged` follows each change.
    nonisolated(unsafe) public private(set) static var isWorking = false
    /// Posted on the main queue whenever `failure` or `lastRun` changes.
    public static let statusChanged = Notification.Name("AtelierFineEdgesStatusChanged")
    /// Posted on the main queue when a matte found in the background is ready, so the editor
    /// renders again with it.
    public static let matteReady = Notification.Name("AtelierFineEdgesMatteReady")

    private static func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: statusChanged, object: nil) }
    }

    /// Forgets the status and quits the model's helper (a download or removal changed which
    /// model runs). Returns at once; the helper quits after a run in progress.
    static func forgetSession() {
        lock.withLock {
            failure = nil
            lastRun = nil
        }
        announce()
        DispatchQueue.global(qos: .utility).async { ModelRunner.fineEdges.stop() }
    }

    /// How many times the model has run in this process (for tests).
    nonisolated(unsafe) static var runs = 0

    /// Whether Fine Edges tries ONNX Runtime's Core ML provider. Off: with the provider really
    /// loading (ALL, not All), Core ML can't compile BiRefNet HR-matting ("Unable to parse ML
    /// Program … Div_1"), and the CPU session made after that failure crashed the app (SIGSEGV in
    /// ONNX Runtime's planner, Mac check of PR #153, Nov 16, 2026). Until then it ran on the
    /// CPU anyway ("All" was refused). LensBlurRealPhotoTests times both.
    nonisolated(unsafe) static var prefersCoreML = false
    /// For FineEdgesSpeedTests: Core ML provider options to try instead of the usual ones, and
    /// the CPU's thread count (nil: ONNX Runtime's own choice).
    nonisolated(unsafe) static var coreMLOptionsOverride: [String: String]?
    nonisolated(unsafe) static var intraOpThreads: Int?

    /// What `model` runs as in its helper: Core ML first when preferred (it compiles the model
    /// once into `coreMLCacheURL`), ONNX Runtime's CPU code otherwise or if Core ML refuses it.
    static func request(_ model: Model) -> ModelRunner.Request {
        ModelRunner.Request(modelPath: model.modelURL.path, optimizationLevels: ["all"],
                            coreML: prefersCoreML ? (coreMLOptionsOverride ?? CoreMLProviderOptions.options(cache: model.coreMLCacheURL)) : nil,
                            threads: intraOpThreads, shape: [1, 3, model.size, model.size])
    }

    /// `model`'s foreground matte of `image` (any size: it is stretched to the model's square),
    /// 0...1, `model.size` × `model.size`, rows from the top. Nil when the model isn't downloaded
    /// or fails (`failure` says why). Runs in the model's helper process (`ModelRunner`).
    public static func matte(of image: CGImage, model: Model) -> [Float]? {
        let size = model.size
        guard model.isInstalled else {
            lock.withLock { failure = Failure.noModel.localizedDescription }
            announce()
            return nil
        }
        guard let pixels = rgba(image, size: size) else { return nil }
        lock.withLock {
            isWorking = true
            runs += 1
            lastRun = "Fine Edges (\(model.name)) is working… (the first time after a download takes longest)"
            failure = nil
        }
        announce()
        defer {
            lock.withLock { isWorking = false }
            announce()
        }
        let started = Date()
        do {
            let input = inputTensor(pixels, size: size).withUnsafeBufferPointer { Data(buffer: $0) }
            let output: ModelRunner.Output
            do {
                output = try ModelRunner.fineEdges.run(request(model), input: input)
            } catch let failure as ModelRunner.Failure {
                throw Failure.run(failure.reason)
            }
            let data = output.data
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
            let line = String(format: "Fine Edges (%@) ran in %.1f s (%@); %.0f%% of the photo is foreground",
                              model.name, seconds, output.usedCoreML ? "Core ML" : "CPU", foreground * 100)
            lock.withLock {
                failure = nil
                lastRun = line
            }
            Log.models.notice("\(line, privacy: .public)")
            return chances
        } catch {
            let reason = error.localizedDescription
            lock.withLock { failure = reason }
            Log.models.error("Fine Edges failed: \(String(describing: error), privacy: .public)")
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
