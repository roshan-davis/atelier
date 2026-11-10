import CoreGraphics
import Foundation

/// The histogram graph as one finished picture: red, green and blue drawn together in a single
/// pass, where they overlap mixing to yellow, cyan, magenta and gray as in Lightroom.
///
/// It used to be three translucent fills blended one over the other in a SwiftUI `Canvas` on the
/// main thread at every render, which Rosh saw as the colors drawing one after another and the
/// graph freezing during a drag (Nov 10, 2026). The picture is made beside the counting, off the
/// main thread, so the view only swaps an image.
public enum HistogramPicture {
    /// Pixels of the picture; the view stretches it to its size (90 pt high at 2x in Develop).
    public static let width = 512
    public static let height = 180

    /// Each channel's color where it is alone, as light that adds up where channels overlap
    /// (all three make a light gray, two make yellow, cyan or magenta).
    static let colors: [(r: Double, g: Double, b: Double)] = [
        (0.56, 0.10, 0.10),
        (0.11, 0.50, 0.14),
        (0.11, 0.18, 0.54),
    ]

    /// Draws `histogram` at `width` x `height` pixels, transparent above the graph. Bins are
    /// lightly smoothed and joined smoothly across columns; the top edge is antialiased.
    public static func make(_ histogram: Histogram, width: Int = HistogramPicture.width,
                            height: Int = HistogramPicture.height) -> CGImage? {
        guard width > 1, height > 0 else { return nil }
        let channels = [histogram.red, histogram.green, histogram.blue].map(smoothed)
        // Each channel's height in pixels, column by column.
        let heights: [[Double]] = channels.map { bins in
            (0..<width).map { column in
                value(of: bins, at: Double(column) / Double(width - 1)) * Double(height)
            }
        }
        let c0 = colors[0], c1 = colors[1], c2 = colors[2]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for column in 0..<width {
            let tops = (heights[0][column], heights[1][column], heights[2][column])
            let tallest = max(tops.0, tops.1, tops.2)
            guard tallest > 0 else { continue }
            // Rows counted from the bottom; only those under the tallest channel are drawn.
            let rows = min(height, Int(tallest.rounded(.up)))
            for row in 0..<rows {
                let y = Double(row)
                let red = min(1, max(0, tops.0 - y))
                let green = min(1, max(0, tops.1 - y))
                let blue = min(1, max(0, tops.2 - y))
                let r = c0.r * red + c1.r * green + c2.r * blue
                let g = c0.g * red + c1.g * green + c2.g * blue
                let b = c0.b * red + c1.b * green + c2.b * blue
                // Premultiplied: the light is the color itself, its alpha what it covers.
                let alpha = min(1, max(red, green, blue, r, g, b))
                let offset = ((height - 1 - row) * width + column) * 4
                pixels[offset] = byte(min(r, alpha))
                pixels[offset + 1] = byte(min(g, alpha))
                pixels[offset + 2] = byte(min(b, alpha))
                pixels[offset + 3] = byte(alpha)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A 1-2-1 blur, so a sparse sample doesn't draw as a comb. The end bins (pure black and
    /// white) keep their own value: a clipping spike stays a spike.
    static func smoothed(_ bins: [Double]) -> [Double] {
        guard bins.count > 2 else { return bins }
        var out = bins
        for i in 1..<(bins.count - 1) {
            out[i] = (bins[i - 1] + 2 * bins[i] + bins[i + 1]) / 4
        }
        return out
    }

    /// The bins read at `fraction` of the width (bin `i` sits at `i / (count - 1)`, as the
    /// graph always drew them), with a smooth step between neighbouring bins.
    static func value(of bins: [Double], at fraction: Double) -> Double {
        guard let last = bins.indices.last, last > 0 else { return bins.first ?? 0 }
        let position = min(Double(last), max(0, fraction * Double(last)))
        let index = min(last - 1, Int(position))
        let t = position - Double(index)
        let eased = t * t * (3 - 2 * t)
        return min(1, max(0, bins[index] + (bins[index + 1] - bins[index]) * eased))
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, (value * 255).rounded())))
    }
}
