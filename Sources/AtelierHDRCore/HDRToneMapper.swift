import Foundation

/// Deterministic single-image qualification engine, independent of Core Image and UI.
/// Both candidates use the same linear source. Virtual exposures contain no extra scene data.
///
/// Speed (Rosh, Nov 12, 2026: "make all the sliders as much smooth as possible"): the work that
/// depends only on the photo and Exposure (luminance, its log, the fine blur and the edge-aware
/// base) is an `Analysis` that a caller keeps between renders, so Range, Microcontrast, Detail,
/// Shadows, Highlights and the panel switches only run the per-pixel pass. Every pass is split
/// across the processor cores by rows or columns. Each output value is computed with exactly
/// the same arithmetic in the same order as before, so the result is bit-for-bit unchanged.
public enum HDRToneMapper {
    /// What a render needs that depends only on the image and the exposure.
    public struct Analysis: Sendable {
        public let width: Int
        public let height: Int
        public let exposure: Float
        let luminance: [Float]
        let logs: [Float]
        let small: [Float]
        let large: [Float]

        /// Whether this analysis was made from an image of this size at this exposure. The
        /// caller keeps one analysis per input image.
        public func matches(_ image: HDRImage, exposure: Float) -> Bool {
            width == image.width && height == image.height && self.exposure == exposure
        }
    }

    public static func analyze(_ image: HDRImage, exposure: Float,
                               cancellation: () throws -> Void = {}) throws -> Analysis {
        try cancellation()
        let width = image.width, height = image.height, count = width * height
        let gain = powf(2, exposure)
        var luminance = [Float](repeating: 0, count: count)
        var logs = [Float](repeating: 0, count: count)
        image.rgb.withUnsafeBufferPointer { rgb in
            luminance.withUnsafeMutableBufferPointer { lum in
                logs.withUnsafeMutableBufferPointer { log in
                    rows(height) { y in
                        for i in (y * width)..<((y + 1) * width) {
                            let l = max(0, (rgb[i*3] * 0.2126 + rgb[i*3+1] * 0.7152 + rgb[i*3+2] * 0.0722) * gain)
                            lum[i] = l
                            log[i] = log2f(max(l, 0.000001))
                        }
                    }
                }
            }
        }
        try cancellation()
        // Spatial scales are relative to full image geometry, so proxy/full-size controls
        // address the same structures. Edge protection limits amplified large transitions.
        let small = blur(logs, width: width, height: height,
                         radius: max(1, Int(Float(max(width, height)) * 0.002)))
        try cancellation()
        let large = try guidedBase(logs, width: width, height: height,
                                   radius: max(1, Int(Float(max(width, height)) * 0.02)), cancellation: cancellation)
        return Analysis(width: width, height: height, exposure: exposure,
                        luminance: luminance, logs: logs, small: small, large: large)
    }

    /// `analysis` is reused when it matches the image and `settings.exposure`; otherwise it is
    /// computed afresh. The result is the same either way.
    public static func render(_ image: HDRImage, settings: HDRSettings, analysis: Analysis? = nil,
                              cancellation: () throws -> Void = {}) throws -> HDRImage {
        try settings.validate()
        try cancellation()
        if !settings.toneEnabled { return image }
        let prepared: Analysis
        if let analysis, analysis.matches(image, exposure: settings.exposure) { prepared = analysis }
        else { prepared = try analyze(image, exposure: settings.exposure, cancellation: cancellation) }
        try cancellation()
        let width = image.width, height = image.height
        let gain = powf(2, settings.exposure)
        var output = image.rgb
        image.rgb.withUnsafeBufferPointer { rgb in
            prepared.luminance.withUnsafeBufferPointer { luminance in
                prepared.logs.withUnsafeBufferPointer { logs in
                    prepared.small.withUnsafeBufferPointer { small in
                        prepared.large.withUnsafeBufferPointer { large in
                            output.withUnsafeMutableBufferPointer { output in
                                rows(height) { y in
                                    for x in 0..<width {
                                        let i = y * width + x
                                        let scale = pixelScale(l: luminance[i], log: logs[i], small: small[i], large: large[i],
                                                               gain: gain, settings: settings)
                                        for c in 0..<3 { output[i*3+c] = max(0, rgb[i*3+c] * scale) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try cancellation()
        return try HDRImage(width: width, height: height, rgb: output)
    }

    /// The factor one pixel's RGB is multiplied by.
    @inline(__always)
    private static func pixelScale(l: Float, log: Float, small: Float, large: Float,
                                   gain: Float, settings: HDRSettings) -> Float {
        let mapped: Float
        switch settings.method {
        case .direct:
            // Compress large-scale log illumination around middle gray, retaining
            // the edge-aware residual. The guided base prevents wide texture halos.
            let anchor = log2f(0.18)
            // Keep deep blacks from turning gray as the illumination range compresses.
            let blackProtection = min(1, max(0, l / 0.06))
            let amount = settings.compression * (large < anchor ? blackProtection : 1)
            let base = anchor + (large - anchor) * (1 - amount * 0.85)
            let local = settings.compression == 0 ? l : exp2f(base + log - large)
            // Restore midtone separation after illumination compression. This avoids
            // equating an HDR look with a uniformly lifted, low-contrast image.
            let shaped = settings.compression == 0 ? local : 0.18 * powf(max(0, local / 0.18), 1.25)
            let k = settings.compression
            mapped = shaped * (1 + k * 0.18) / (1 + k * shaped)
        case .virtualExposureFusion:
            // Explicit -2/0/+2 EV display plates, normalized positive well-exposedness
            // weights. This is a global baseline for comparison, not Mertens pyramids.
            var sum: Float = 0, weights: Float = 0
            for ev: Float in [-2, 0, 2] {
                let plate = min(1, l * powf(2, ev))
                let weight = expf(-powf((plate - 0.5) / 0.24, 2) / 2) + 0.0001
                sum += plate * weight; weights += weight
            }
            let fused = sum / weights
            mapped = l * (1 - settings.compression) + fused * settings.compression
        }
        let shadowMask = min(1, l / 0.08)
        let highlightMask = 1 / (1 + max(0, l - 0.7) * 4)
        let protection: Float = settings.artifactsEnabled ? (1 - settings.shadowProtection + settings.shadowProtection * shadowMask)
            * (1 - settings.highlightProtection + settings.highlightProtection * highlightMask) : 1
        let fine = max(-0.5, min(0.5, log - small))
        let coarse = max(-0.5, min(0.5, small - large))
        let boundaryProtection = 1 / (1 + abs(log - small) * 4)
        let texture = powf(2, protection * (settings.detail * fine * 2
            + settings.microcontrast * coarse * 3 * boundaryProtection))
        return l > 0.000001 ? mapped / l * gain * texture : gain
    }

    /// Self-guided filter in log2 luminance. Epsilon is in squared stops; the base
    /// follows strong boundaries while smoothing illumination within textured surfaces.
    private static func guidedBase(_ values: [Float], width: Int, height: Int, radius: Int,
                                   cancellation: () throws -> Void) throws -> [Float] {
        let mean = blur(values, width: width, height: height, radius: radius)
        let squares = values.map { $0 * $0 }
        let meanSquare = blur(squares, width: width, height: height, radius: radius)
        try cancellation()
        var a = mean, b = mean
        for i in values.indices {
            let variance = max(0, meanSquare[i] - mean[i] * mean[i])
            a[i] = variance / (variance + 0.12)
            b[i] = (1 - a[i]) * mean[i]
        }
        let meanA = blur(a, width: width, height: height, radius: radius)
        let meanB = blur(b, width: width, height: height, radius: radius)
        try cancellation()
        return values.indices.map { meanA[$0] * values[$0] + meanB[$0] }
    }

    /// Separable sliding-window mean with replicated borders; bounded O(pixel count) work.
    /// Rows, then columns, are spread across the cores; each sum runs in the same order as
    /// a single-threaded pass.
    private static func blur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var horizontal = values, result = values
        let r = min(radius, max(width, height)), divisor = Float(2*r+1)
        values.withUnsafeBufferPointer { values in
            horizontal.withUnsafeMutableBufferPointer { horizontal in
                rows(height) { y in
                    var sum: Float = 0
                    for dx in -r...r { sum += values[y*width + min(width-1, max(0, dx))] }
                    for x in 0..<width {
                        horizontal[y*width+x] = sum / divisor
                        sum += values[y*width + min(width-1, x+r+1)] - values[y*width + max(0, x-r)]
                    }
                }
            }
        }
        horizontal.withUnsafeBufferPointer { horizontal in
            result.withUnsafeMutableBufferPointer { result in
                rows(width) { x in
                    var sum: Float = 0
                    for dy in -r...r { sum += horizontal[min(height-1, max(0, dy))*width+x] }
                    for y in 0..<height {
                        result[y*width+x] = sum / divisor
                        sum += horizontal[min(height-1, y+r+1)*width+x] - horizontal[max(0, y-r)*width+x]
                    }
                }
            }
        }
        return result
    }

    /// Runs `body` for every index in 0..<count, in contiguous bands spread across the cores.
    /// Each index is visited exactly once, so independent per-row work gives the same result
    /// as a plain loop.
    static func rows(_ count: Int, _ body: (Int) -> Void) {
        guard count > 0 else { return }
        let bands = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
        guard bands > 1, count >= 64 else {
            for index in 0..<count { body(index) }
            return
        }
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let start = count * band / bands, end = count * (band + 1) / bands
            for index in start..<end { body(index) }
        }
    }
}
