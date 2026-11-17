import CoreGraphics
import CoreImage
import Foundation

/// Basic > White Balance helpers, as in Lightroom: the presets menu, Auto, and the White
/// Balance Selector (click something that should be neutral).
public enum WhiteBalance {
    /// A Lightroom RAW preset. `tint` is Lightroom's absolute tint; the stored Tint is relative
    /// to the camera's, so applying a preset subtracts the photo's as-shot tint.
    public struct Preset: Hashable, Sendable, Identifiable {
        public let name: String
        public let temperature: Double
        public let tint: Double
        public var id: String { name }
    }

    public static let presets = [
        Preset(name: "Daylight", temperature: 5500, tint: 10),
        Preset(name: "Cloudy", temperature: 6500, tint: 10),
        Preset(name: "Shade", temperature: 7500, tint: 10),
        Preset(name: "Tungsten", temperature: 2850, tint: 0),
        Preset(name: "Fluorescent", temperature: 3800, tint: 21),
        Preset(name: "Flash", temperature: 5500, tint: 0),
    ]

    /// Temp in Kelvin and Tint (as stored, relative to the camera's) that make the photo
    /// neutral. With `area` (0 to 1 from the top left of the cropped photo) the colors there
    /// become neutral, for the White Balance Selector; without it, the colors that are nearly
    /// gray do, for Auto. Nil when the photo can't be rendered or has nothing to go on.
    public static func neutral(session: DevelopSession, settings: DevelopSettings, area: CGRect? = nil,
                               asShotTint: Double = 0) -> (temperature: Double, tint: Double)? {
        // Measure the photo as the RAW engine and profile render it, without the color sliders.
        var base = settings.lensGeometryKey
        base.crop = settings.crop
        base.profile = settings.profile
        base.exposure = settings.exposure
        func measure(_ mired: Double, _ tint: Double, nearGray: Bool) -> SIMD2<Double>? {
            var s = base
            s.temperature = (1e6 / mired).rounded()
            s.tint = tint
            guard let pixels = sample(session, s) else { return nil }
            return meanColor(pixels, area: area, nearGray: nearGray)
        }

        let startMired = 1e6 / (settings.temperature ?? session.asShotTemperature)
        var mired = startMired, tint = settings.tint
        let tintRange = (-150 - asShotTint)...(150 - asShotTint)
        for iteration in 0..<5 {
            // Auto starts from the average of the midtones, then trusts the nearly gray colors.
            let nearGray = area == nil && iteration > 0
            guard let color = measure(mired, tint, nearGray: nearGray) else { return iteration == 0 ? nil : (1e6 / mired, tint) }
            if (color * color).sum() < 0.002 * 0.002, iteration > 0 { break }
            guard let warmer = measure(mired - 20, tint, nearGray: nearGray),
                  let greener = measure(mired, tint - 10, nearGray: nearGray) else { break }
            let j1 = (warmer - color) / -20, j2 = (greener - color) / -10
            let det = j1.x * j2.y - j2.x * j1.y
            guard abs(det) > 1e-12 else { break }
            let error = -color
            let dm = (error.x * j2.y - j2.x * error.y) / det
            let dt = (j1.x * error.y - error.x * j1.y) / det
            mired = min(1e6 / 2000, max(1e6 / 50000, mired + min(120, max(-120, dm))))
            tint = min(tintRange.upperBound, max(tintRange.lowerBound, tint + min(60, max(-60, dt))))
        }
        return ((1e6 / mired / 10).rounded() * 10, tint.rounded())
    }

    /// Long edge of the renders measured.
    static let sampleSize = 256.0

    /// The photo rendered small in sRGB, as packed RGBA8 rows from the top.
    static func sample(_ session: DevelopSession, _ settings: DevelopSettings) -> (data: [UInt8], width: Int, height: Int)? {
        guard var image = session.image(with: settings) else { return nil }
        let extent = image.extent
        let factor = min(1, sampleSize / Double(max(extent.width, extent.height)))
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor)))
        guard let cgImage = DevelopRenderer.shared.cgImage(image, colorSpace: DevelopRenderer.sRGB) else { return nil }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: DevelopRenderer.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (data, width, height) : nil
    }

    /// The average Oklab a, b of the pixels in `area`, or of the midtones (only the nearly gray
    /// ones with `nearGray`), skipping clipped pixels.
    static func meanColor(_ pixels: (data: [UInt8], width: Int, height: Int), area: CGRect?,
                          nearGray: Bool) -> SIMD2<Double>? {
        let (data, width, height) = pixels
        var region = CGRect(x: 0, y: 0, width: width, height: height)
        if let area {
            // At least three pixels across, so the click lands on something.
            let w = max(3, area.width * Double(width)), h = max(3, area.height * Double(height))
            region = CGRect(x: area.midX * Double(width) - w / 2, y: area.midY * Double(height) - h / 2, width: w, height: h)
                .intersection(region)
            guard !region.isNull, !region.isEmpty else { return nil }
        }
        let linear = LookSample.linearTable
        var sum = SIMD2<Double>(0, 0), total = 0.0
        for y in Int(region.minY.rounded(.down))..<Int(region.maxY.rounded(.up)) {
            for x in Int(region.minX.rounded(.down))..<Int(region.maxX.rounded(.up)) {
                let i = (y * width + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                if max(r, g, b) >= 254 { continue }
                let lab = LookSample.oklab(linear[r], linear[g], linear[b])
                var weight = 1.0
                if area == nil {
                    guard lab.0 > 0.25, lab.0 < 0.95 else { continue }
                    if nearGray {
                        let chroma = (lab.1 * lab.1 + lab.2 * lab.2).squareRoot()
                        weight = exp(-pow(chroma / 0.04, 2))
                    }
                }
                sum += SIMD2(lab.1, lab.2) * weight
                total += weight
            }
        }
        return total > 1e-6 ? sum / total : nil
    }
}
