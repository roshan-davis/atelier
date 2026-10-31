import Foundation

/// Deterministic single-image qualification engine, independent of Core Image and UI.
/// Both candidates use the same linear source. Virtual exposures contain no extra scene data.
public enum HDRToneMapper {
    public static func render(_ image: HDRImage, settings: HDRSettings,
                              cancellation: () throws -> Void = {}) throws -> HDRImage {
        try settings.validate()
        try cancellation()
        if !settings.toneEnabled { return image }
        let count = image.width * image.height
        let gain = powf(2, settings.exposure)
        var luminance = [Float](repeating: 0, count: count)
        for i in 0..<count {
            luminance[i] = max(0, (image.rgb[i*3] * 0.2126 + image.rgb[i*3+1] * 0.7152
                                   + image.rgb[i*3+2] * 0.0722) * gain)
        }
        // Spatial scales are relative to full image geometry, so proxy/full-size controls
        // address the same structures. Edge protection limits amplified large transitions.
        let logs = luminance.map { log2f(max($0, 0.000001)) }
        let small = try blur(logs, width: image.width, height: image.height,
                             radius: max(1, Int(Float(max(image.width, image.height)) * 0.002)), cancellation: cancellation)
        let large = try guidedBase(logs, width: image.width, height: image.height,
                             radius: max(1, Int(Float(max(image.width, image.height)) * 0.02)), cancellation: cancellation)
        var output = image.rgb
        for y in 0..<image.height {
            try cancellation()
            for x in 0..<image.width {
                let i = y * image.width + x, l = luminance[i]
                let mapped: Float
                switch settings.method {
                case .direct:
                    // Compress large-scale log illumination around middle gray, retaining
                    // the edge-aware residual. The guided base prevents wide texture halos.
                    let anchor = log2f(0.18)
                    // Keep deep blacks from turning gray as the illumination range compresses.
                    let blackProtection = min(1, max(0, l / 0.06))
                    let amount = settings.compression * (large[i] < anchor ? blackProtection : 1)
                    let base = anchor + (large[i] - anchor) * (1 - amount * 0.85)
                    let local = settings.compression == 0 ? l : exp2f(base + logs[i] - large[i])
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
                let fine = max(-0.5, min(0.5, logs[i] - small[i]))
                let coarse = max(-0.5, min(0.5, small[i] - large[i]))
                let boundaryProtection = 1 / (1 + abs(logs[i] - small[i]) * 4)
                let texture = powf(2, protection * (settings.detail * fine * 2
                    + settings.microcontrast * coarse * 3 * boundaryProtection))
                let scale = l > 0.000001 ? mapped / l * gain * texture : gain
                for c in 0..<3 { output[i*3+c] = max(0, image.rgb[i*3+c] * scale) }
            }
        }
        return try HDRImage(width: image.width, height: image.height, rgb: output)
    }

    /// Self-guided filter in log2 luminance. Epsilon is in squared stops; the base
    /// follows strong boundaries while smoothing illumination within textured surfaces.
    private static func guidedBase(_ values: [Float], width: Int, height: Int, radius: Int,
                                   cancellation: () throws -> Void) throws -> [Float] {
        let mean = try blur(values, width: width, height: height, radius: radius, cancellation: cancellation)
        let squares = values.map { $0 * $0 }
        let meanSquare = try blur(squares, width: width, height: height, radius: radius, cancellation: cancellation)
        var a = mean, b = mean
        for i in values.indices {
            let variance = max(0, meanSquare[i] - mean[i] * mean[i])
            a[i] = variance / (variance + 0.12)
            b[i] = (1 - a[i]) * mean[i]
        }
        let meanA = try blur(a, width: width, height: height, radius: radius, cancellation: cancellation)
        let meanB = try blur(b, width: width, height: height, radius: radius, cancellation: cancellation)
        return values.indices.map { meanA[$0] * values[$0] + meanB[$0] }
    }

    /// Separable sliding-window mean with replicated borders; bounded O(pixel count) work.
    private static func blur(_ values: [Float], width: Int, height: Int, radius: Int,
                             cancellation: () throws -> Void) throws -> [Float] {
        var horizontal = values, result = values
        let r = min(radius, max(width, height)), divisor = Float(2*r+1)
        for y in 0..<height {
            try cancellation()
            var sum: Float = 0
            for dx in -r...r { sum += values[y*width + min(width-1, max(0, dx))] }
            for x in 0..<width {
                horizontal[y*width+x] = sum / divisor
                sum += values[y*width + min(width-1, x+r+1)] - values[y*width + max(0, x-r)]
            }
        }
        for x in 0..<width {
            try cancellation()
            var sum: Float = 0
            for dy in -r...r { sum += horizontal[min(height-1, max(0, dy))*width+x] }
            for y in 0..<height {
                result[y*width+x] = sum / divisor
                sum += horizontal[min(height-1, y+r+1)*width+x] - horizontal[max(0, y-r)*width+x]
            }
        }
        return result
    }
}
