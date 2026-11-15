import CoreGraphics
import CoreImage
import Foundation
import OnnxRuntimeBindings

/// Depth Range masks (AT-068): how far away each part of the photo is, from Depth Anything V2
/// Small (Lihe Yang et al., 2024, Apache 2.0), an optional 50 MB download in Settings > AI or
/// the mask panel. It runs on this Mac with ONNX Runtime (Core ML where it can), once per photo
/// and lens geometry, in under a second; photos are never sent anywhere.
///
/// The model gives relative depth (no meters): Atelier spreads each photo's own range over
/// 0 (nearest) to 100 (farthest), as Lightroom's Depth Range slider reads.
public enum DepthMap {
    /// onnx-community's ONNX export of Depth Anything V2 Small (Apache 2.0), half precision,
    /// pinned to the repository revision and the file's SHA-256.
    public static let downloadURL = URL(string: "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/4472b7362082ad9968fee890ca0f1e5aca36b93d/onnx/model_fp16.onnx")!
    public static let sha256 = "2df6223f206b5164e21f664ace61dabeb9bb6a49b8b5a3e00510b4807d0f5b04"
    public static let downloadSize = "50 MB"
    public static let modelName = "Depth Anything V2 Small"

    /// Where the model lives, named by its checksum so a new file is a new name.
    public static var modelURL: URL {
        ModelDownload.folder.appendingPathComponent("DepthAnythingV2-Small-\(sha256.prefix(12)).onnx")
    }

    /// Where Core ML keeps its compiled copy (rebuilt if deleted).
    static var coreMLCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Atelier/Models/DepthAnything-CoreML-\(sha256.prefix(12))", isDirectory: true)
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    /// Posted on the main queue when a depth map found in the background is ready, or the model
    /// was downloaded or removed, so the editor renders again.
    public static let ready = Notification.Name("AtelierDepthMapReady")

    /// Why the model last failed, for the mask panel; nil when it worked.
    nonisolated(unsafe) public private(set) static var failure: String?

    // MARK: Download

    public static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ModelDownload.fetch(downloadURL, sha256: sha256, to: modelURL, progress: progress)
        forgetSession()
        announce()
    }

    public static func remove() throws {
        forgetSession()
        try? FileManager.default.removeItem(at: coreMLCacheURL)
        if isInstalled { try FileManager.default.removeItem(at: modelURL) }
        announce()
    }

    private static func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: ready, object: nil) }
    }

    // MARK: Running

    /// One photo's depth: `width` × `height` values, rows from the top, 0 nearest to 1 farthest.
    public struct Field: Sendable {
        public let width: Int
        public let height: Int
        public let values: [Float]

        /// The depth at a point (top-left fractions of the photo), 0...1.
        public func value(atX x: Double, y: Double) -> Float {
            let column = min(width - 1, max(0, Int(x * Double(width))))
            let row = min(height - 1, max(0, Int(y * Double(height))))
            return values[row * width + column]
        }

        /// The depths inside `box` (top-left fractions), for picking a range.
        public func values(in box: DevelopSettings.MaskRect) -> [Float] {
            let x0 = min(width - 1, max(0, Int(box.x * Double(width))))
            let y0 = min(height - 1, max(0, Int(box.y * Double(height))))
            let x1 = min(width - 1, max(x0, Int(((box.x + box.width) * Double(width)).rounded(.up)) - 1))
            let y1 = min(height - 1, max(y0, Int(((box.y + box.height) * Double(height)).rounded(.up)) - 1))
            var out: [Float] = []
            out.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
            for row in y0...y1 {
                for column in x0...x1 { out.append(values[row * width + column]) }
            }
            return out
        }

        /// Select Sky's mask, 0...1, on the same grid: the farthest depths (fading in from 0.9 to
        /// 0.97 of the photo's range; Depth Anything puts the sky at its farthest) that are
        /// connected to the top row through far pixels, so a distant wall or the far end of a
        /// room with no sky above it isn't taken. All zero when no far part touches the top.
        public var sky: [Float] {
            let low: Float = 0.9, high: Float = 0.97
            var reached = [Bool](repeating: false, count: values.count)
            var stack: [Int] = []
            for column in 0..<width where values[column] >= low {
                reached[column] = true
                stack.append(column)
            }
            while let index = stack.popLast() {
                let row = index / width, column = index % width
                var neighbors: [Int] = []
                if row > 0 { neighbors.append(index - width) }
                if row < height - 1 { neighbors.append(index + width) }
                if column > 0 { neighbors.append(index - 1) }
                if column < width - 1 { neighbors.append(index + 1) }
                for next in neighbors where !reached[next] && values[next] >= low {
                    reached[next] = true
                    stack.append(next)
                }
            }
            var out = [Float](repeating: 0, count: values.count)
            for i in values.indices where reached[i] {
                let t = min(1, max(0, (values[i] - low) / (high - low)))
                out[i] = t * t * (3 - 2 * t)
            }
            return out
        }

        /// As a one-channel float image on `extent` (the corrected photo's frame), stretched to it.
        func image(on extent: CGRect) -> CIImage? { Self.image(values, width: width, height: height, on: extent) }

        /// `values` (`width` × `height`, rows from the top) as a one-channel float image on `extent`.
        static func image(_ values: [Float], width: Int, height: Int, on extent: CGRect) -> CIImage? {
            // A 32-bit float gray CGImage, whose rows run from the top, read as stored values.
            let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            guard let provider = CGDataProvider(data: data as CFData),
                  let gray = CGColorSpace(name: CGColorSpace.linearGray),
                  let cgImage = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: gray,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            // Clamped first, so the photo's edges don't fade toward 0 (near) when stretched.
            return DevelopRenderer.rawMask(cgImage).clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .cropped(to: extent)
        }
    }

    /// The model's input size for a photo `width` × `height`: the short edge 518 pixels, the long
    /// edge kept in proportion (at most twice as long), both whole multiples of 14, as the
    /// model's preprocessor_config.json asks.
    static func inputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let short = 518.0
        let ratio = min(2, Double(max(width, height)) / Double(max(1, min(width, height))))
        let long = max(14, Int((short * ratio / 14).rounded()) * 14)
        return width >= height ? (long, Int(short)) : (Int(short), long)
    }

    /// The model's raw output (relative inverse depth: higher is nearer) turned into 0 nearest to
    /// 1 farthest, spread over the photo's own range. The nearest and farthest 1% are clipped so
    /// a speck doesn't squeeze everything else together.
    static func normalized(_ raw: [Float]) -> [Float] {
        let finite = raw.filter(\.isFinite)
        guard finite.count >= 2 else { return raw.map { _ in 0.5 } }
        let sorted = finite.sorted()
        let low = sorted[sorted.count / 100], high = sorted[sorted.count - 1 - sorted.count / 100]
        let span = max(high - low, 1e-6)
        return raw.map { value in
            guard value.isFinite else { return 1 }
            return 1 - min(1, max(0, (value - low) / span))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var environment: ORTEnv?
    nonisolated(unsafe) private static var session: ORTSession?

    private static func forgetSession() {
        lock.lock()
        session = nil
        failure = nil
        lock.unlock()
    }

    /// The model, loaded once: Core ML runs what it can, ONNX Runtime's CPU code the rest. Call
    /// with the lock held.
    private static func loadedSession() throws -> ORTSession {
        if let session { return session }
        guard isInstalled else { throw Failure("the depth model isn't downloaded.") }
        let env = try environment ?? ORTEnv(loggingLevel: .warning)
        environment = env
        func options(coreML: Bool, level: ORTGraphOptimizationLevel = .basic) throws -> ORTSessionOptions {
            let options = try ORTSessionOptions()
            // Basic at most: the extended fusions (SimplifiedLayerNormFusion) break on this
            // half-precision export ("Attempting to get index by a name which does not exist:
            // InsertedPrecisionFreeCast_…", Rosh's Mac, Nov 15, 2026).
            try options.setGraphOptimizationLevel(level)
            let cache = coreMLCacheURL
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            if coreML {
                try options.appendCoreMLExecutionProvider(withOptionsV2: ["ModelFormat": "MLProgram",
                                                                         "MLComputeUnits": "All",
                                                                         "ModelCacheDirectory": cache.path])
            }
            return options
        }
        let made: ORTSession
        do {
            made = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options(coreML: true))
        } catch {
            NSLog("Atelier: Depth Range with Core ML failed (%@), using the CPU", "\(error)")
            do {
                made = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options(coreML: false))
            } catch {
                NSLog("Atelier: Depth Range on the CPU failed (%@), trying without graph optimizations", "\(error)")
                made = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options(coreML: false, level: .none))
            }
        }
        session = made
        return made
    }

    struct Failure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { "The depth model didn't run: \(reason)" }
    }

    /// The depth of `image` (the corrected photo as sRGB), or nil when the model isn't
    /// downloaded or fails (`failure` says why). Takes under a second; call it off the main
    /// thread.
    public static func estimate(_ image: CGImage) -> Field? {
        let size = inputSize(width: image.width, height: image.height)
        guard let pixels = rgba(image, width: size.width, height: size.height) else { return nil }
        let input = inputTensor(pixels, width: size.width, height: size.height)
        lock.lock()
        defer { lock.unlock() }
        do {
            let session = try loadedSession()
            guard let inputName = try session.inputNames().first,
                  let outputName = try session.outputNames().first else { throw Failure("no inputs or outputs") }
            let shape: [NSNumber] = [1, 3, NSNumber(value: size.height), NSNumber(value: size.width)]
            // onnx-community's half-precision exports keep float input and output, as Fine Edges' does.
            let data = NSMutableData(data: input.withUnsafeBufferPointer { Data(buffer: $0) })
            let value = try ORTValue(tensorData: data, elementType: .float, shape: shape)
            let outputs = try session.run(withInputs: [inputName: value], outputNames: [outputName], runOptions: nil)
            guard let output = outputs[outputName] else { throw Failure("no output") }
            let result = try output.tensorData() as Data
            let count = size.width * size.height
            let raw: [Float]
            if result.count == count * 4 {
                raw = result.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else if result.count == count * 2 {
                raw = result.withUnsafeBytes { $0.bindMemory(to: UInt16.self).map(FineEdges.floatFromHalf) }
            } else {
                throw Failure("unexpected output size \(result.count) bytes")
            }
            failure = nil
            return Field(width: size.width, height: size.height, values: normalized(raw))
        } catch {
            failure = error.localizedDescription
            NSLog("Atelier: Depth Range failed: %@", "\(error)")
            return nil
        }
    }

    /// The image drawn at `width` × `height`, RGBA, rows from the top (bicubic, as the model's
    /// preprocessor resamples).
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: DevelopRenderer.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// 1 × 3 × height × width, RGB planes, 0...1 normalized with ImageNet's mean and deviation.
    static func inputTensor(_ pixels: [UInt8], width: Int, height: Int) -> [Float] {
        let mean: [Float] = [0.485, 0.456, 0.406], deviation: [Float] = [0.229, 0.224, 0.225]
        let plane = width * height
        var out = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane {
            for c in 0..<3 {
                out[c * plane + i] = (Float(pixels[i * 4 + c]) / 255 - mean[c]) / deviation[c]
            }
        }
        return out
    }
}
