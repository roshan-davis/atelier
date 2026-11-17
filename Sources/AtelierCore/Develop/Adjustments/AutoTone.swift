import Foundation

/// Basic > Auto: sets Exposure, Highlights, Shadows, Whites and Blacks from the photo's
/// histogram, like Lightroom's Auto button. Contrast is left as it is. Each step renders
/// the photo through the real pipeline and measures the result, so it accounts for the
/// profile and white balance.
public enum AutoTone {
    public static let parameters: [DevelopSettings.Parameter] = [.exposure, .highlights, .shadows, .whites, .blacks]

    /// The open photo's settings with the Auto tone values, or nil when it can't be rendered.
    /// With `only`, just that slider changes (Shift-double-click on a slider's name).
    public static func apply(session: DevelopSession, settings: DevelopSettings,
                             only: DevelopSettings.Parameter? = nil) -> DevelopSettings? {
        var result = settings
        func sorted(_ s: DevelopSettings) -> [Double]? {
            guard let pixels = WhiteBalance.sample(session, s) else { return nil }
            var values: [Double] = []
            values.reserveCapacity(pixels.width * pixels.height)
            for i in stride(from: 0, to: pixels.data.count, by: 4) {
                let r = Double(pixels.data[i]), g = Double(pixels.data[i + 1]), b = Double(pixels.data[i + 2])
                values.append((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255)
            }
            return values.isEmpty ? nil : values.sorted()
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            values[min(values.count - 1, max(0, Int(p * Double(values.count))))]
        }
        func wants(_ parameter: DevelopSettings.Parameter) -> Bool { only == nil || only == parameter }

        // Measure without the sliders Auto sets (only the one asked for, with `only`).
        var base = settings
        for parameter in parameters where wants(parameter) { base[parameter] = 0 }

        if wants(.exposure) {
            // Exposure: put the median at about 46% (sRGB-encoded), the middle of a typical
            // well-exposed photo; two passes, since the profile's curve isn't linear.
            for _ in 0..<2 {
                guard let values = sorted(base) else { return nil }
                let median = max(0.02, percentile(values, 0.5))
                let step = log2(linear(0.46) / linear(median))
                base.exposure = min(2, max(-2, ((base.exposure + step) * 20).rounded() / 20))
            }
            result.exposure = base.exposure
        }
        guard let values = sorted(base) else { return nil }
        let bright = Double(values.filter { $0 > 0.9 }.count) / Double(values.count)
        let dark = Double(values.filter { $0 < 0.12 }.count) / Double(values.count)
        if wants(.highlights) {
            // Pull highlights down when a lot of the photo is near white.
            result.highlights = -min(70, (max(0, bright - 0.02) * 400).rounded())
        }
        if wants(.shadows) {
            result.shadows = min(60, (max(0, dark - 0.08) * 200).rounded())
        }
        if wants(.whites) {
            // Whites: bring the brightest 0.5% up to white, without clipping more.
            let top = percentile(values, 0.995)
            result.whites = min(60, max(-30, ((0.98 - top) / 0.1 * 100).rounded()))
        }
        if wants(.blacks) {
            // Blacks: set the darkest 0.5% near black.
            let bottom = percentile(values, 0.005)
            result.blacks = min(0, max(-60, ((0.02 - bottom) / 0.1 * 100).rounded()))
        }
        return result
    }

    private static func linear(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
}
