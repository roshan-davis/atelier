import CoreGraphics
import Foundation

/// RGB and luminance histogram of a rendered image, for the Develop panel.
public struct Histogram: Sendable, Hashable {
    public static let binCount = 64

    /// Each array has `binCount` values scaled so the tallest bin across channels is 1.
    public var red: [Double]
    public var green: [Double]
    public var blue: [Double]
    public var luminance: [Double]
    /// Share of pixels at pure black or pure white in any channel, for clipping warnings.
    public var shadowClipping: Double
    public var highlightClipping: Double

    /// Samples a downscaled copy, so this is cheap enough to run after every render.
    public init?(image: CGImage, sampleSize: Int = 256) {
        let scale = min(1, Double(sampleSize) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var r = [Double](repeating: 0, count: Self.binCount)
        var g = r, b = r, l = r
        var lowClipped = 0, highClipped = 0
        let shift = 256 / Self.binCount
        for i in 0..<(width * height) {
            let red = Int(pixels[i * 4]), green = Int(pixels[i * 4 + 1]), blue = Int(pixels[i * 4 + 2])
            r[red / shift] += 1
            g[green / shift] += 1
            b[blue / shift] += 1
            let luma = (red * 54 + green * 183 + blue * 19) >> 8
            l[min(255, luma) / shift] += 1
            if red == 0 || green == 0 || blue == 0 { lowClipped += 1 }
            if red == 255 || green == 255 || blue == 255 { highClipped += 1 }
        }
        // Ignore the end bins when scaling so a clipped spike doesn't flatten the rest.
        let peak = max(1, [r, g, b, l].map { $0[1..<(Self.binCount - 1)].max() ?? 1 }.max() ?? 1)
        func normalized(_ bins: [Double]) -> [Double] { bins.map { min(1, $0 / peak) } }
        red = normalized(r)
        green = normalized(g)
        blue = normalized(b)
        luminance = normalized(l)
        let total = Double(width * height)
        shadowClipping = Double(lowClipped) / total
        highlightClipping = Double(highClipped) / total
    }
}
