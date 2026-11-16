import CoreImage
import Foundation
import OnnxRuntimeBindings

/// Detail > Noise Reduction > AI Denoise (AT-067): PMRID (Wang et al., "Practical Deep Raw Image
/// Denoising on Mobile Devices", ECCV 2020; megvii-research/PMRID, Apache License 2.0), a 4 MB
/// raw-domain denoiser built into the app (Models/PMRID.onnx) and run with ONNX Runtime (Core ML
/// where it can, the CPU otherwise). Nothing is downloaded and nothing leaves the Mac.
///
/// Apple's RAW engine doesn't hand out the sensor's mosaic, so the model is fed one rebuilt from
/// the decoded photo: the full-size, linear decode (no tone curve, no noise reduction) is sampled
/// at red, green, green and blue sites of a 2 × 2 grid, which keeps each site's own noise. The
/// noise level is measured on the photo itself (`estimate`), so no camera needs calibrating. The
/// noise the model takes out at each site is carried through Apple's tone curve (fitted per photo,
/// `ChannelCurve`), spread to every pixel (`spread`) and kept as the photo's noise picture
/// (`Residual`). A render subtracts Amount × that picture from the decode, before the camera
/// match, with Apple's own noise reduction off. It is found once per file and lens-profile
/// setting, in the background while editing (the photo shows Apple's noise reduction until then)
/// and before rendering in exports.
public enum AIDenoise {
    /// Posted on the main queue when a photo's noise picture is ready, so the editor renders again.
    public static let ready = Notification.Name("AtelierAIDenoiseReady")
    /// Posted on the main queue whenever a file's `status` changes.
    public static let statusChanged = Notification.Name("AtelierAIDenoiseStatusChanged")

    /// Where AI Denoise is for one file.
    public enum Status: Equatable, Sendable {
        case working
        case done(seconds: Double, coreML: Bool)
        case failed(String)
    }

    /// AI Denoise's state for `url`, or nil when it hasn't run on it this launch.
    public static func status(for url: URL) -> Status? { store.status(for: url) }

    /// What the Detail panel shows under the slider, or nil for nothing.
    public static func statusText(for url: URL?, isRAW: Bool, amount: Double) -> String? {
        guard let url else { return nil }
        guard isRAW else { return amount > 0 ? "AI Denoise works on RAW photos only." : nil }
        switch status(for: url) {
        case .working: return "Finding the noise… The photo shows without AI Denoise until it's done."
        case .done(let seconds, let coreML):
            return amount > 0 ? String(format: "Denoised on this Mac in %.1f s (%@).", seconds, coreML ? "Core ML" : "CPU") : nil
        case .failed(let reason): return "AI Denoise didn't run: \(reason)"
        case nil: return nil
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: The noise picture

    /// The noise AI Denoise takes out of one photo: full size, upright, origin at zero, in the
    /// working space, as it shows after Apple's tone curve at the as-shot white balance and
    /// Exposure 0. Alpha is 1.
    public final class Residual: @unchecked Sendable {
        let image: CIImage
        /// The boosted decode's average color (working space), so a later White Balance or
        /// Exposure change scales the noise with the photo (see `SpotPatches.colorShift`).
        let mean: [Double]
        let bytes: Int

        init(image: CIImage, mean: [Double], bytes: Int) {
            self.image = image
            self.mean = mean
            self.bytes = bytes
        }

        /// `output` (Apple's decode with its noise reduction off, any size and origin) with
        /// `amount` (0...1) of the noise taken out.
        func apply(to output: CIImage, amount: Double) -> CIImage {
            guard amount > 0, let kernel = AIDenoise.kernel, !output.extent.isEmpty, !image.extent.isEmpty else { return output }
            let target = output.extent
            var noise = image
            let sx = target.width / image.extent.width, sy = target.height / image.extent.height
            if abs(sx - 1) > 1e-6 || abs(sy - 1) > 1e-6 {
                // Lanczos averages the noise the way a smaller decode does.
                noise = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy,
                                                                                    kCIInputAspectRatioKey: sx / sy])
            }
            noise = noise.transformed(by: CGAffineTransform(translationX: target.minX - noise.extent.minX,
                                                            y: target.minY - noise.extent.minY))
                .clampedToExtent()
            let ratio = SpotPatches.colorShift(from: mean, to: output, in: target)
                ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            return kernel.apply(extent: target, roiCallback: { _, rect in rect },
                                arguments: [output, noise, ratio, Float(min(1, max(0, amount)))])?
                .cropped(to: target) ?? output
        }
    }

    private static let kernel: CIKernel? = RuntimeKernels.build("""
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        // ratio: how much brighter each channel is now than when the noise was found.
        [[stitchable]] float4 atelierAIDenoise(coreimage::sampler image, coreimage::sampler noise, coreimage::sampler ratio,
                                               float amount, coreimage::destination dest) {
            float4 color = image.sample(image.transform(dest.coord()));
            float3 n = noise.sample(noise.transform(dest.coord())).rgb;
            float3 gain = ratio.sample(ratio.transform(dest.coord())).rgb;
            return float4(max(color.rgb - amount * gain * n, float3(0.0)), color.a);
        }
        """)?["atelierAIDenoise"]

    /// Whether the kernel built, for tests.
    static var kernelAvailable: Bool { kernel != nil }

    // MARK: Cache

    static let store = Store()

    /// Noise pictures by file and lens-profile setting, found one at a time.
    final class Store: @unchecked Sendable {
        private let residuals = NSCache<NSString, Residual>()
        private let lock = NSLock()
        private var pending: Set<String> = []
        /// Files whose noise couldn't be found this launch, so a render doesn't try again.
        private var failed: [String: String] = [:]
        private var statuses: [String: Status] = [:]
        /// One photo at a time: a 24 MP photo takes about 1 GB while it is worked on.
        private let queue = DispatchQueue(label: "atelier.ai-denoise", qos: .userInitiated)

        init() {
            // A 24 MP noise picture is about 190 MB.
            residuals.totalCostLimit = 1_200_000_000
        }

        func status(for url: URL) -> Status? {
            lock.lock()
            defer { lock.unlock() }
            return statuses[url.path]
        }

        /// The noise picture for `file` (`fileKey(_:)`) if it has been found.
        func cached(file: String, profileCorrections: Bool) -> Residual? {
            residuals.object(forKey: "\(file)|\(profileCorrections)" as NSString)
        }

        /// The noise picture for `url` (`file` is its `fileKey(_:)`); with `waits` false it is found
        /// in the background and nil is returned until `AIDenoise.ready` is posted.
        func residual(for url: URL, file: String, profileCorrections: Bool, waits: Bool, context: CIContext) -> Residual? {
            let key = "\(file)|\(profileCorrections)"
            if let found = residuals.object(forKey: key as NSString) { return found }
            lock.lock()
            if failed[key] != nil || (!waits && pending.contains(key)) {
                lock.unlock()
                return nil
            }
            if !waits { pending.insert(key) }
            lock.unlock()
            guard waits else {
                queue.async { [self] in
                    _ = find(key: key, url: url, profileCorrections: profileCorrections, context: context)
                    lock.lock()
                    pending.remove(key)
                    lock.unlock()
                    DispatchQueue.main.async { NotificationCenter.default.post(name: AIDenoise.ready, object: nil) }
                }
                return nil
            }
            // Behind any photo already being worked on, which may be this one.
            return queue.sync { find(key: key, url: url, profileCorrections: profileCorrections, context: context) }
        }

        /// Call on `queue`.
        private func find(key: String, url: URL, profileCorrections: Bool, context: CIContext) -> Residual? {
            if let found = residuals.object(forKey: key as NSString) { return found }
            set(.working, for: url)
            let started = Date()
            do {
                let (residual, coreML) = try AIDenoise.make(url: url, profileCorrections: profileCorrections, context: context)
                residuals.setObject(residual, forKey: key as NSString, cost: residual.bytes)
                let seconds = Date().timeIntervalSince(started)
                NSLog("Atelier: AI Denoise found %@'s noise in %.1f s (%@)", url.lastPathComponent, seconds,
                      coreML ? "Core ML" : "CPU")
                set(.done(seconds: seconds, coreML: coreML), for: url)
                return residual
            } catch {
                let reason = error.localizedDescription
                NSLog("Atelier: AI Denoise failed on %@: %@", url.lastPathComponent, reason)
                lock.lock()
                failed[key] = reason
                lock.unlock()
                set(.failed(reason), for: url)
                return nil
            }
        }

        private func set(_ status: Status, for url: URL) {
            lock.lock()
            statuses[url.path] = status
            lock.unlock()
            DispatchQueue.main.async { NotificationCenter.default.post(name: AIDenoise.statusChanged, object: nil) }
        }

        /// The file and its modification date, so a file changed on disk (Edit In) is denoised again.
        /// A Develop session works it out once, as it opens.
        static func fileKey(_ url: URL) -> String {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        }
    }

    // MARK: Finding the noise

    /// Decodes `url` the way a Develop session does (lens profile on or off, as-shot white balance,
    /// Exposure 0) with Apple's noise reduction off, and finds its noise picture.
    static func make(url: URL, profileCorrections: Bool, context: CIContext) throws -> (Residual, coreML: Bool) {
        func decode(boosted: Bool, longEdge: CGFloat?) throws -> CIImage {
            guard let raw = CIRAWFilter(imageURL: url) else { throw Failure("Apple's RAW engine can't read this file.") }
            if raw.isLensCorrectionSupported, raw.isLensCorrectionEnabled != profileCorrections {
                raw.isLensCorrectionEnabled = profileCorrections
            }
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
            if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
            if !boosted { raw.boostAmount = 0 }
            if let longEdge {
                let native = max(raw.nativeSize.width, raw.nativeSize.height)
                if native > longEdge { raw.scaleFactor = Float(longEdge / native) }
            }
            guard let image = raw.outputImage, !image.extent.isEmpty, !image.extent.isInfinite else {
                throw Failure("the photo couldn't be decoded.")
            }
            return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        // Apple's tone curve, per channel, from small linear and boosted decodes.
        let smallLinear = try decode(boosted: false, longEdge: 1024)
        let smallBoosted = try decode(boosted: true, longEdge: 1024)
        guard let linearPixels = rgb(of: smallLinear, context: context),
              let boostedPixels = rgb(of: smallBoosted, context: context),
              let mean = SpotPatches.mean(of: smallBoosted, in: smallBoosted.extent, context: context)
        else { throw Failure("the photo couldn't be read.") }
        let curves = (0..<3).map { c in
            ChannelCurve.fit(linear: stride(from: c, to: linearPixels.count, by: 3).map { linearPixels[$0] },
                             boosted: stride(from: c, to: boostedPixels.count, by: 3).map { boostedPixels[$0] })
        }

        // The mosaic, from the full-size linear decode, kept by Core Image while it is read in
        // strips so the RAW file is decoded once.
        let full = try RenderMemory.shared.kept(decode(boosted: false, longEdge: nil))
        let width = Int(full.extent.width), height = Int(full.extent.height)
        guard width >= 32, height >= 32 else { throw Failure("the photo is too small.") }
        guard var mosaic = Mosaic(full, width: width, height: height, context: context) else {
            throw Failure("the photo couldn't be read.")
        }
        let scale = max(mosaic.planes.lazy.map { $0.max() ?? 0 }.max() ?? 0, 1e-6)
        for i in 0..<4 { mosaic.planes[i] = mosaic.planes[i].map { $0 / scale } }
        guard let noise = estimate(mosaic.planes, width: mosaic.planeWidth, height: mosaic.planeHeight) else {
            throw Failure("the noise couldn't be measured.")
        }
        let (denoised, coreML) = try denoise(mosaic.planes, width: mosaic.planeWidth, height: mosaic.planeHeight,
                                             noise: noise)
        // What came out at each site, back in the decode's units and through the tone curve.
        let planes = mosaic.planes
        var sites: [[Float]] = []
        for i in 0..<4 {
            let curve = curves[Mosaic.channel[i]]
            let before = planes[i], after = denoised[i]
            let count = before.count
            var out = [Float](repeating: 0, count: count)
            out.withUnsafeMutableBufferPointer { buffer in
                let pointer = buffer.baseAddress!
                let chunks = 16
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    for j in (count * chunk / chunks)..<(count * (chunk + 1) / chunks) {
                        pointer[j] = curve(before[j] * scale) - curve(after[j] * scale)
                    }
                }
            }
            sites.append(out)
        }
        let halves = spread(sites, planeWidth: mosaic.planeWidth, planeHeight: mosaic.planeHeight,
                            width: width, height: height)
        return (residual(halves, width: width, height: height, mean: mean), coreML)
    }

    /// A noise picture from `spread`'s half floats (rows from the top).
    static func residual(_ halves: [UInt16], width: Int, height: Int, mean: [Double]) -> Residual {
        let data = halves.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 8, size: CGSize(width: width, height: height),
                            format: .RGBAh, colorSpace: nil)
        return Residual(image: image, mean: mean, bytes: data.count)
    }

    /// `image`'s pixels (origin at zero) as RGB floats in the working space, rows from the top.
    static func rgb(of image: CIImage, context: CIContext) -> [Float]? {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { return nil }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
        }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return rgb
    }

    /// The decoded photo sampled on a 2 × 2 red, green, green, blue grid: four planes, each half
    /// the photo's width and height, rows from the top.
    struct Mosaic {
        /// Which color each plane holds (0 red, 1 green, 2 blue), and its site in the 2 × 2 cell.
        static let channel = [0, 1, 1, 2]
        static let site = [(0, 0), (0, 1), (1, 0), (1, 1)]  // (row, column)

        var planes: [[Float]]
        let planeWidth: Int
        let planeHeight: Int

        init(planes: [[Float]], planeWidth: Int, planeHeight: Int) {
            self.planes = planes
            self.planeWidth = planeWidth
            self.planeHeight = planeHeight
        }

        /// Reads `image` (origin at zero, `width` × `height`) in strips, so a large photo isn't
        /// held as floats all at once.
        init?(_ image: CIImage, width: Int, height: Int, context: CIContext) {
            planeWidth = width / 2
            planeHeight = height / 2
            planes = [[Float]](repeating: [Float](repeating: 0, count: planeWidth * planeHeight), count: 4)
            let strip = 512
            var buffer = [Float](repeating: 0, count: width * strip * 4)
            var top = 0
            while top < planeHeight * 2 {
                let rows = min(strip, planeHeight * 2 - top)
                // Core Image's y axis points up.
                buffer.withUnsafeMutableBytes { bytes in
                    context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                                   bounds: CGRect(x: 0, y: height - top - rows, width: width, height: rows),
                                   format: .RGBAf, colorSpace: nil)
                }
                for row in 0..<rows {
                    let y = top + row, py = y / 2, dy = y % 2
                    for i in 0..<4 where Mosaic.site[i].0 == dy {
                        let dx = Mosaic.site[i].1, c = Mosaic.channel[i]
                        let base = row * width * 4
                        for px in 0..<planeWidth {
                            planes[i][py * planeWidth + px] = buffer[base + (px * 2 + dx) * 4 + c]
                        }
                    }
                }
                top += rows
            }
        }
    }

    // MARK: Measuring the noise

    /// The noise of `planes` (0...1, rows from the top) as variance = a × level + b, measured on
    /// the photo: in 16 × 16 blocks a Laplacian takes out the picture and leaves the noise, and
    /// at each brightness the flattest tenth of the blocks says how strong it is. Nil when too
    /// little of the photo is usable.
    static func estimate(_ planes: [[Float]], width: Int, height: Int) -> (a: Double, b: Double)? {
        let block = 16
        let across = (width - 2) / block, down = (height - 2) / block
        guard across >= 1, down >= 1 else { return nil }
        var samples: [(mean: Double, variance: Double)] = []
        samples.reserveCapacity(planes.count * across * down)
        let norm = 1 / 20.0.squareRoot()
        for p in planes {
            for by in 0..<down {
                for bx in 0..<across {
                    var sum = 0.0, dSum = 0.0, dSquares = 0.0
                    for y in (1 + by * block)..<(1 + (by + 1) * block) {
                        let row = y * width
                        for x in (1 + bx * block)..<(1 + (bx + 1) * block) {
                            let v = Double(p[row + x])
                            let d = (4 * v - Double(p[row - width + x]) - Double(p[row + width + x])
                                - Double(p[row + x - 1]) - Double(p[row + x + 1])) * norm
                            sum += v
                            dSum += d
                            dSquares += d * d
                        }
                    }
                    let n = Double(block * block)
                    let mean = sum / n, dMean = dSum / n
                    guard mean > 0.002, mean < 0.9 else { continue }
                    samples.append((mean, max(0, dSquares / n - dMean * dMean)))
                }
            }
        }
        samples.sort { $0.mean < $1.mean }
        let bins = 40
        var xs: [Double] = [], ys: [Double] = []
        for b in 0..<bins {
            let low = samples.count * b / bins, high = samples.count * (b + 1) / bins
            guard high - low >= 20 else { continue }
            let bin = samples[low..<high]
            let flattest = bin.map { $0.variance }.sorted().prefix(max(5, bin.count / 10))
            xs.append(bin.reduce(0) { $0 + $1.mean } / Double(bin.count))
            // The flattest tenth of 16 × 16 blocks reads about 0.82 of the true variance
            // (measured on synthetic noise).
            ys.append(flattest.reduce(0, +) / Double(flattest.count) * 1.22)
        }
        guard xs.count >= 3 else { return nil }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
        }
        guard sxx > 0 else { return nil }
        let a = sxy / sxx
        return (a, my - a * mx)
    }

    // MARK: Running the model

    /// PMRID's noise model at ISO 1600, the level it was trained to expect after its k-sigma
    /// transform, in its 959-level raw units.
    private static let levels = 959.0
    private static let anchorK = 0.0005995267 * 1600 + 0.00868861
    private static let anchorS = 7.11772e-7 * 1600 * 1600 + 6.514934e-4 * 1600 + 0.11492713
    /// The model's square tile (fixed, so Core ML can compile it) and the margin each tile shares
    /// with its neighbours.
    static let tile = 512
    static let overlap = 32

    /// `planes` (0...1) with their noise taken out, by tiles. Throws when the model can't run.
    static func denoise(_ planes: [[Float]], width: Int, height: Int, noise: (a: Double, b: Double))
        throws -> ([[Float]], coreML: Bool) {
        // k-sigma: scale the photo so its noise looks like the ISO 1600 the model knows. The gain
        // is kept inside the range the model was trained on (about ISO 100 to 6400).
        let k = min(5, max(0.05, noise.a * levels))
        let s = max(0, noise.b) * levels * levels
        let ck = anchorK / k
        let cb = (s / (k * k) - anchorS / (anchorK * anchorK)) * anchorK
        let gain = Float(ck * 256), offset = Float(cb / levels * 256)
        let (session, coreML) = try loadedSession()
        let step = tile - 2 * overlap
        let tilesDown = (height + step - 1) / step, tilesAcross = (width + step - 1) / step
        var out = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: 4)
        var input = [Float](repeating: 0, count: 4 * tile * tile)
        for ty in 0..<tilesDown {
            for tx in 0..<tilesAcross {
                let sy = ty * step - overlap, sx = tx * step - overlap
                let rows = (0..<tile).map { mirror(sy + $0, height) }
                let columns = (0..<tile).map { mirror(sx + $0, width) }
                for c in 0..<4 {
                    let plane = planes[c]
                    for y in 0..<tile {
                        let source = rows[y] * width, target = (c * tile + y) * tile
                        for x in 0..<tile { input[target + x] = plane[source + columns[x]] * gain + offset }
                    }
                }
                let result = try run(session, input)
                let y0 = ty * step, y1 = min(height, y0 + step), x0 = tx * step, x1 = min(width, x0 + step)
                for c in 0..<4 {
                    for y in y0..<y1 {
                        let source = (c * tile + y - sy) * tile - sx, target = y * width
                        for x in x0..<x1 { out[c][target + x] = (result[source + x] - offset) / gain }
                    }
                }
            }
        }
        idle.touch()
        return (out, coreML)
    }

    /// Index `i` reflected into 0..<n (…, 2, 1, 0, 1, 2, …, n-1, n-2, …).
    static func mirror(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let period = 2 * n - 2
        let m = ((i % period) + period) % period
        return m < n ? m : period - m
    }

    private static func run(_ session: ORTSession, _ input: [Float]) throws -> [Float] {
        let data = NSMutableData(data: input.withUnsafeBufferPointer { Data(buffer: $0) })
        let value = try ORTValue(tensorData: data, elementType: .float,
                                 shape: [1, 4, NSNumber(value: tile), NSNumber(value: tile)])
        // No arena shrinkage per tile (it would allocate again for every tile): a tile's working
        // memory is small, and the whole model is unloaded once idle (`idle`).
        let outputs = try session.run(withInputs: ["input": value], outputNames: ["output"], runOptions: nil)
        guard let output = outputs["output"] else { throw Failure("the model gave no output.") }
        let bytes = try output.tensorData() as Data
        let result: [Float]
        if bytes.count == input.count * 4 {
            result = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } else if bytes.count == input.count * 2 {
            result = bytes.withUnsafeBytes { $0.bindMemory(to: UInt16.self).map(FineEdges.floatFromHalf) }
        } else {
            throw Failure("the model gave \(bytes.count) bytes.")
        }
        guard result.allSatisfy(\.isFinite) else { throw Failure("the model gave numbers out of range.") }
        return result
    }

    private static let sessionLock = NSLock()
    /// The loaded model, unloaded after `OnnxHost.idleSeconds` without a run (`idle`).
    nonisolated(unsafe) private static var session: (session: ORTSession, coreML: Bool)?
    private static let idle = OnnxHost.IdleUnload("AI Denoise") { unloadSession() }

    /// Unloads the model and gives back the memory its runs used (AT-077). A denoise in
    /// progress keeps its own reference and finishes; the next one loads the model again.
    public static func unloadSession() {
        idle.cancel()
        sessionLock.withLock { session = nil }
    }
    /// The built-in model's version (first 12 hex digits of PMRID.onnx's SHA-256), so a new
    /// model compiles into a new Core ML cache folder.
    static let modelVersion = "2c76727c7b20"

    /// The built-in model in AtelierCore's resources.
    static var modelURL: URL? { BundledModel.resourceURL(name: "PMRID", extension: "onnx") }

    /// Whether PMRID tries ONNX Runtime's Core ML provider (off: see `loadedSession`).
    static let usesCoreML = false

    /// The model, loaded once: Core ML runs what it can, ONNX Runtime's CPU code the rest.
    private static func loadedSession() throws -> (ORTSession, coreML: Bool) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        idle.touch()
        if let session { return (session.session, coreML: session.coreML) }
        guard let url = modelURL else { throw Failure("PMRID.onnx isn't in the app's resources.") }
        let env = try OnnxHost.environment()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cache = caches.appendingPathComponent("Atelier/Models/PMRID-CoreML-\(modelVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        func options(coreML: Bool) throws -> ORTSessionOptions {
            let options = try ORTSessionOptions()
            try OnnxHost.tune(options)
            try options.setGraphOptimizationLevel(.all)
            if coreML {
                try options.appendCoreMLExecutionProvider(withOptionsV2: CoreMLProviderOptions.options(cache: cache))
            }
            return options
        }
        let cpu = try ORTSession(env: env, modelPath: url.path, sessionOptions: options(coreML: false))
        var made = (session: cpu, coreML: false)
        // Core ML stays off for PMRID: with the provider really loading (ALL, not All), ONNX
        // Runtime 1.24.2's Core ML ConvTranspose check crashes the app (SIGSEGV in
        // ConvTransposeOpBuilder::IsOpSupportedImpl, Mac check of PR #153, Nov 16, 2026), and a
        // crash can't be caught. Until then AI Denoise ran on the CPU anyway ("All" was refused).
        if usesCoreML { do {
            let accelerated = try ORTSession(env: env, modelPath: url.path, sessionOptions: options(coreML: true))
            // Core ML may run in half precision on the Neural Engine: check its answer once against
            // the CPU's on a textured tile, and keep the CPU if they disagree.
            let probe = (0..<(4 * tile * tile)).map { Float(64 + 16 * sin(Double($0 % 977) * 0.37)) }
            let fast = try run(accelerated, probe), reference = try run(cpu, probe)
            let difference = zip(fast, reference).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            if difference > 2 { throw Failure("Core ML's result differed from the CPU's by \(difference)") }
            made = (session: accelerated, coreML: true)
        } catch {
            NSLog("Atelier: AI Denoise runs on the CPU (%@)", "\(error)")
        } }
        session = made
        return (made.session, coreML: made.coreML)
    }

    // MARK: Tone curve and spreading

    /// One channel of Apple's RAW tone curve (`boostAmount`), as a table fitted on the photo:
    /// boosted value by linear value. Straight through zero below the table, straight on above it.
    struct ChannelCurve {
        let xs: [Float]
        let ys: [Float]

        static let identity = ChannelCurve(xs: [0, 1], ys: [0, 1])

        static func fit(linear: [Float], boosted: [Float]) -> ChannelCurve {
            let bins = 64
            guard let top = linear.max(), top > 1e-3 else { return .identity }
            let low = log(Float(1e-4)), high = log(top)
            var sumX = [Double](repeating: 0, count: bins), sumY = [Double](repeating: 0, count: bins)
            var count = [Int](repeating: 0, count: bins)
            for (l, b) in zip(linear, boosted) where l >= 1e-4 && l.isFinite && b.isFinite {
                let bin = min(bins - 1, max(0, Int((log(l) - low) / (high - low) * Float(bins))))
                sumX[bin] += Double(l)
                sumY[bin] += Double(b)
                count[bin] += 1
            }
            var xs: [Float] = [], ys: [Float] = []
            for i in 0..<bins where count[i] >= 8 {
                let x = Float(sumX[i] / Double(count[i])), y = Float(sumY[i] / Double(count[i]))
                guard xs.last.map({ x > $0 }) ?? true else { continue }
                xs.append(x)
                ys.append(max(y, ys.last ?? 0))
            }
            guard xs.count >= 2, xs[0] > 0 else { return .identity }
            return ChannelCurve(xs: xs, ys: ys)
        }

        func callAsFunction(_ x: Float) -> Float {
            let n = xs.count
            if x <= xs[0] { return x * ys[0] / xs[0] }
            if x >= xs[n - 1] {
                let slope = max(0, (ys[n - 1] - ys[n - 2]) / max(xs[n - 1] - xs[n - 2], 1e-9))
                return ys[n - 1] + (x - xs[n - 1]) * slope
            }
            var lo = 0, hi = n - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if xs[mid] <= x { lo = mid } else { hi = mid }
            }
            let t = (x - xs[lo]) / (xs[hi] - xs[lo])
            return ys[lo] + (ys[hi] - ys[lo]) * t
        }
    }

    /// The noise found at the mosaic's sites spread to every pixel of each channel (a 3 × 3
    /// bilinear kernel, normalized by the sites it covers), as half-float RGBA (alpha 1), rows
    /// from the top.
    static func spread(_ sites: [[Float]], planeWidth: Int, planeHeight: Int, width: Int, height: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * height * 4)
        let weights: [Float] = [0.25, 0.5, 0.25, 0.5, 1, 0.5, 0.25, 0.5, 0.25]
        let one = half(1)
        out.withUnsafeMutableBufferPointer { buffer in
            let pointer = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    var sum = SIMD3<Float>(repeating: 0), weight = SIMD3<Float>(repeating: 0)
                    for dy in -1...1 {
                        let ny = mirror(y + dy, height), py = ny / 2
                        guard py < planeHeight else { continue }
                        for dx in -1...1 {
                            let nx = mirror(x + dx, width), px = nx / 2
                            guard px < planeWidth else { continue }
                            let i = (ny % 2) * 2 + nx % 2
                            let c = Mosaic.channel[i], w = weights[(dy + 1) * 3 + dx + 1]
                            sum[c] += w * sites[i][py * planeWidth + px]
                            weight[c] += w
                        }
                    }
                    let o = (y * width + x) * 4
                    for c in 0..<3 { pointer[o + c] = half(weight[c] > 0 ? sum[c] / weight[c] : 0) }
                    pointer[o + 3] = one
                }
            }
        }
        return out
    }

    /// `value` as IEEE half-precision bits, rounded to nearest (no `Float16`, so it builds for Intel).
    static func half(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xff) - 127 + 15
        var mantissa = bits & 0x7f_ffff
        if exponent >= 31 { return sign | 0x7c00 }
        if exponent <= 0 {
            if exponent < -10 { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - exponent)
            return sign | UInt16((mantissa + (1 << (shift - 1))) >> shift)
        }
        let rounded = mantissa + 0x1000
        if rounded & 0x80_0000 != 0 {
            return exponent + 1 >= 31 ? sign | 0x7c00 : sign | UInt16((exponent + 1) << 10)
        }
        return sign | UInt16(exponent << 10) | UInt16(rounded >> 13)
    }
}
