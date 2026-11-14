import CoreGraphics
import Foundation

/// A gray copy of a photo that the culling measures read: sharpness (variance of the Laplacian)
/// in any part of the frame, whether that blur runs in one direction, and exposure.
public struct GrayPlane: Sendable {
    public let width: Int
    public let height: Int
    /// Row 0 is the top of the picture.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The image scaled so its long side is at most `maxPixel` (never up).
    public init?(_ image: CGImage, maxPixel: Int = 1024) {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(3, Int(Double(image.width) * scale)), height = max(3, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = gray.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Default interpolation, as the sharpness measure has always used.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: gray)
    }

    /// The whole frame in pixels.
    public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// A Vision rectangle (0...1, origin bottom left) in this plane's pixels (origin top left),
    /// clipped to the frame.
    public func pixelRect(fromVision box: CGRect) -> CGRect {
        let rect = CGRect(x: box.minX * Double(width), y: (1 - box.maxY) * Double(height),
                          width: box.width * Double(width), height: box.height * Double(height))
        return rect.intersection(bounds)
    }

    /// Variance of the Laplacian inside `rect` (pixels): blur and missed focus lower it. Only
    /// comparable between photos of the same scene. 0 when the rect is too small.
    public func laplacianVariance(in rect: CGRect? = nil) -> Double {
        let area = (rect ?? bounds).intersection(bounds)
        let x0 = max(1, Int(area.minX)), x1 = min(width - 1, Int(area.maxX))
        let y0 = max(1, Int(area.minY)), y1 = min(height - 1, Int(area.maxY))
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { return 0 }
        var sum = 0.0, sumSquares = 0.0, count = 0.0
        pixels.withUnsafeBufferPointer { gray in
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 {
                    let center = Double(gray[row + x]) * 4
                    let around = Double(gray[row + x - 1]) + Double(gray[row + x + 1])
                        + Double(gray[row - width + x]) + Double(gray[row + width + x])
                    let value = around - center
                    sum += value
                    sumSquares += value * value
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    /// The Laplacian's sums on a `cells` × `cells` grid, so the sharpness of any region can be
    /// worked out later without the pixels (`CullSharpnessGrid.variance(in:)`): every photo of a
    /// group is then measured on the same region.
    public func laplacianGrid(cells: Int = 16) -> CullSharpnessGrid {
        var grid = CullSharpnessGrid(cells: cells)
        guard width > 2, height > 2 else { return grid }
        pixels.withUnsafeBufferPointer { gray in
            for y in 1..<(height - 1) {
                let row = y * width
                let cy = min(cells - 1, y * cells / height)
                for x in 1..<(width - 1) {
                    let center = Double(gray[row + x]) * 4
                    let around = Double(gray[row + x - 1]) + Double(gray[row + x + 1])
                        + Double(gray[row - width + x]) + Double(gray[row + width + x])
                    let value = around - center
                    let cell = cy * cells + min(cells - 1, x * cells / width)
                    grid.sum[cell] += value
                    grid.squares[cell] += value * value
                    grid.count[cell] += 1
                }
            }
        }
        return grid
    }

    /// How much the edges inside `rect` run one way (0 all ways, 1 one way), from the structure
    /// tensor. Motion blur wipes out the edges across the motion and raises it; missed focus
    /// softens every edge alike. Only meaningful against another shot of the same scene.
    public func edgeCoherence(in rect: CGRect? = nil) -> Double {
        let area = (rect ?? bounds).intersection(bounds)
        let x0 = max(1, Int(area.minX)), x1 = min(width - 1, Int(area.maxX))
        let y0 = max(1, Int(area.minY)), y1 = min(height - 1, Int(area.maxY))
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { return 0 }
        var xx = 0.0, yy = 0.0, xy = 0.0
        pixels.withUnsafeBufferPointer { gray in
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 {
                    let gx = (Double(gray[row + x + 1]) - Double(gray[row + x - 1])) / 2
                    let gy = (Double(gray[row + width + x]) - Double(gray[row - width + x])) / 2
                    xx += gx * gx
                    yy += gy * gy
                    xy += gx * gy
                }
            }
        }
        let trace = xx + yy
        guard trace > 0 else { return 0 }
        let difference = ((xx - yy) * (xx - yy) + 4 * xy * xy).squareRoot()
        return difference / trace
    }

    /// Mean brightness in linear light (0...1) and the shares of the frame that are clipped
    /// (at or above 250) or crushed (at or below 5).
    public func exposure() -> CullExposure {
        var histogram = [Int](repeating: 0, count: 256)
        pixels.withUnsafeBufferPointer { gray in
            for value in gray { histogram[Int(value)] += 1 }
        }
        let total = Double(max(pixels.count, 1))
        var linear = 0.0
        for (level, count) in histogram.enumerated() where count > 0 {
            linear += Double(count) * GrayPlane.linear(Double(level) / 255)
        }
        let highlights = Double(histogram[250...].reduce(0, +)) / total
        let shadows = Double(histogram[...5].reduce(0, +)) / total
        return CullExposure(brightness: linear / total, highlights: highlights, shadows: shadows)
    }

    /// sRGB-encoded to linear light.
    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

/// A photo's exposure as culling measures it.
public struct CullExposure: Sendable, Equatable {
    /// Mean brightness in linear light, 0...1.
    public var brightness: Double
    /// Share of the frame clipped to white.
    public var highlights: Double
    /// Share of the frame crushed to black.
    public var shadows: Double

    public init(brightness: Double = 0.18, highlights: Double = 0, shadows: Double = 0) {
        self.brightness = brightness
        self.highlights = highlights
        self.shadows = shadows
    }

    /// Stops brighter (positive) or darker than `other`.
    public func stops(from other: CullExposure) -> Double {
        log2(max(brightness, 1e-4) / max(other.brightness, 1e-4))
    }
}

/// The Laplacian's sums per cell of a grid over the frame (rows from the top), from
/// `GrayPlane.laplacianGrid`.
public struct CullSharpnessGrid: Sendable, Equatable {
    public let cells: Int
    var sum: [Double]
    var squares: [Double]
    var count: [Double]

    public init(cells: Int) {
        self.cells = cells
        sum = [Double](repeating: 0, count: cells * cells)
        squares = sum
        count = sum
    }

    /// Variance of the Laplacian over the cells a Vision rectangle (0...1, origin bottom left)
    /// touches; 0 when nothing was measured there.
    public func variance(in box: CGRect) -> Double {
        let n = Double(cells)
        let left = Double(box.minX) * n, right = Double(box.maxX) * n
        let top = (1 - Double(box.maxY)) * n, bottom = (1 - Double(box.minY)) * n
        let x0 = clampCell(Int(left.rounded(.down)))
        let x1 = max(x0, clampCell(Int(right.rounded(.up)) - 1))
        let y0 = clampCell(Int(top.rounded(.down)))
        let y1 = max(y0, clampCell(Int(bottom.rounded(.up)) - 1))
        var s = 0.0, q = 0.0, c = 0.0
        for y in y0...y1 {
            for x in x0...x1 {
                let i = y * cells + x
                s += sum[i]
                q += squares[i]
                c += count[i]
            }
        }
        guard c > 0 else { return 0 }
        let mean = s / c
        return q / c - mean * mean
    }

    private func clampCell(_ index: Int) -> Int {
        max(0, min(cells - 1, index))
    }
}
