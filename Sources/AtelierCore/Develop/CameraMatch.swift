import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// The base look for a RAW file, matched to the JPEG preview the camera embedded in it, like
/// Lightroom's Camera Matching profiles. Apple's RAW engine renders without the camera's picture
/// style or shadow lift (Active D-Lighting), so its default render is darker and flatter than the
/// preview the grid shows first. A tone curve fitted to the two histograms, plus a saturation
/// factor, brings the render to the camera's look before any of the user's adjustments.
public struct CameraMatch: Sendable, Equatable {
    /// Output for evenly spaced inputs from 0 to 1, in sRGB-encoded values.
    public var curve: [Float]
    public var saturation: Double

    public static let identity = CameraMatch(curve: [0, 1], saturation: 1)

    public var isIdentity: Bool {
        saturation == 1 && curve.enumerated().allSatisfy { abs(Double($1) - Double($0) / Double(curve.count - 1)) < 0.002 }
    }

    /// The curve's output at `x` (0 to 1), interpolated between samples.
    public func value(at x: Double) -> Double {
        let position = min(1, max(0, x)) * Double(curve.count - 1)
        let index = min(curve.count - 2, Int(position))
        let t = position - Double(index)
        return Double(curve[index]) * (1 - t) + Double(curve[index + 1]) * t
    }

    // MARK: Fitting

    /// Long edge of the images compared; histograms need few pixels.
    static let fitSize = 512
    /// How far the curve may move a tone, so an odd preview can't wreck the render.
    static let maxShift = 0.3

    /// Fits the curve that gives `source` the tonal distribution of `target`, both packed
    /// RGBA8 in sRGB. Histogram matching ignores where pixels are, so the embedded preview may be
    /// cropped or sized a little differently from the RAW.
    public static func fit(source: [UInt8], target: [UInt8]) -> CameraMatch {
        let bins = 256
        let sourceHistogram = histogram(source, bins: bins)
        let targetHistogram = histogram(target, bins: bins)
        let sourceTotal = sourceHistogram.reduce(0, +), targetTotal = targetHistogram.reduce(0, +)
        guard sourceTotal > 0, targetTotal > 0 else { return .identity }

        // Cumulative share of the target at or below each bin's upper edge.
        var targetCDF = [Double](repeating: 0, count: bins)
        var running = 0.0
        for i in 0..<bins {
            running += targetHistogram[i]
            targetCDF[i] = running / targetTotal
        }
        // The target tone holding the same share of pixels as each source bin's middle.
        var map = [Double?](repeating: nil, count: bins)
        running = 0
        for i in 0..<bins where sourceHistogram[i] > 0 {
            let share = (running + sourceHistogram[i] / 2) / sourceTotal
            running += sourceHistogram[i]
            var k = 0
            while k < bins - 1, targetCDF[k] < share { k += 1 }
            let below = k == 0 ? 0 : targetCDF[k - 1]
            let width = targetCDF[k] - below
            let t = width > 0 ? (share - below) / width : 0.5
            map[i] = (Double(k) + t) / Double(bins)
        }
        // Pin black and white, fill empty bins linearly, then smooth and keep it rising.
        map[0] = map[0].map { min($0, 0.02) } ?? 0
        map[bins - 1] = 1
        var filled = [Double](repeating: 0, count: bins)
        var last = 0
        filled[0] = map[0]!
        for i in 1..<bins {
            guard let y = map[i] else { continue }
            for j in (last + 1)...i {
                filled[j] = filled[last] + (y - filled[last]) * Double(j - last) / Double(i - last)
            }
            last = i
        }
        var curve = [Float](repeating: 0, count: bins)
        var previous = 0.0
        for i in 0..<bins {
            let lower = max(0, i - 6), upper = min(bins - 1, i + 6)
            var y = filled[lower...upper].reduce(0, +) / Double(upper - lower + 1)
            let x = Double(i) / Double(bins - 1)
            y = min(x + maxShift, max(x - maxShift, y))
            if i == 0 { y = min(y, 0.02) }
            if i == bins - 1 { y = 1 }
            y = max(previous, y)
            curve[i] = Float(y)
            previous = y
        }

        // Saturation: the camera's mean chroma against the source's once the curve is applied.
        let match = CameraMatch(curve: curve, saturation: 1)
        let sourceChroma = meanChroma(source) { match.value(at: $0) }
        let targetChroma = meanChroma(target) { $0 }
        var saturation = 1.0
        if sourceChroma > 0.02, targetChroma > 0.02 {
            saturation = min(1.35, max(0.85, targetChroma / sourceChroma))
        }
        return CameraMatch(curve: curve, saturation: saturation)
    }

    private static func histogram(_ pixels: [UInt8], bins: Int) -> [Double] {
        var counts = [Double](repeating: 0, count: bins)
        var i = 0
        while i + 3 < pixels.count {
            let luma = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
            counts[min(bins - 1, Int(luma / 256 * Double(bins)))] += 1
            i += 4
        }
        return counts
    }

    private static func meanChroma(_ pixels: [UInt8], curve: (Double) -> Double) -> Double {
        var sum = 0.0, count = 0.0
        var i = 0
        while i + 3 < pixels.count {
            let r = curve(Double(pixels[i]) / 255), g = curve(Double(pixels[i + 1]) / 255),
                b = curve(Double(pixels[i + 2]) / 255)
            sum += max(r, g, b) - min(r, g, b)
            count += 1
            i += 4
        }
        return count > 0 ? sum / count : 0
    }

    // MARK: Measuring a file

    /// Compares the file's embedded preview with a neutral render. Nil when the file has no
    /// usable preview, so the render stays Apple's.
    static func measure(url: URL, context: CIContext) -> CameraMatch? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                  kCGImageSourceCreateThumbnailFromImageAlways: false,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: fitSize,
              ] as CFDictionary),
              max(preview.width, preview.height) >= 160,
              let raw = CIRAWFilter(imageURL: url) else { return nil }
        let longEdge = max(raw.nativeSize.width, raw.nativeSize.height)
        if longEdge > 0 { raw.scaleFactor = Float(min(1, Double(fitSize) / Double(longEdge))) }
        guard let output = raw.outputImage,
              let rendered = context.createCGImage(output, from: output.extent.integral, format: .RGBA8,
                                                   colorSpace: DevelopRenderer.sRGB) else { return nil }
        // Small embedded previews are often letterboxed (160 x 120 around a 3:2 photo); the bars
        // would skew the histogram, so keep the middle at the render's shape.
        guard let framed = cropped(preview, toAspectOf: rendered),
              let sourcePixels = pixels(rendered), let targetPixels = pixels(framed) else { return nil }
        return fit(source: sourcePixels, target: targetPixels)
    }

    /// The middle of `image` with `reference`'s long-to-short ratio, whichever way each is turned.
    static func cropped(_ image: CGImage, toAspectOf reference: CGImage) -> CGImage? {
        let ratio = Double(max(reference.width, reference.height)) / Double(max(1, min(reference.width, reference.height)))
        let landscape = image.width >= image.height
        var long = Double(max(image.width, image.height)), short = Double(min(image.width, image.height))
        if long / short > ratio { long = short * ratio } else { short = long / ratio }
        guard short >= 100 else { return nil }
        let width = landscape ? long : short, height = landscape ? short : long
        let rect = CGRect(x: (Double(image.width) - width) / 2, y: (Double(image.height) - height) / 2,
                          width: width, height: height).integral
        return image.cropping(to: rect)
    }

    /// The image drawn into sRGB RGBA8.
    static func pixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: DevelopRenderer.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    // MARK: Rendering

    /// Applies the curve in sRGB-encoded values, as the tone curve does, then the saturation.
    func apply(to input: CIImage) -> CIImage {
        guard !isIdentity else { return input }
        var image = input
        let samples = 1024
        let lut = (0..<samples).flatMap { i -> [Float] in
            let y = Float(value(at: Double(i) / Double(samples - 1)))
            return [y, y, y]
        }
        let curves = CIFilter.colorCurves()
        curves.inputImage = image
        curves.curvesData = lut.withUnsafeBufferPointer { Data(buffer: $0) }
        curves.curvesDomain = CIVector(x: 0, y: 1)
        curves.colorSpace = DevelopRenderer.sRGB
        image = curves.outputImage ?? image
        if saturation != 1 {
            let color = CIFilter.colorControls()
            color.inputImage = image
            color.saturation = Float(saturation)
            color.brightness = 0
            color.contrast = 1
            image = color.outputImage ?? image
        }
        return image
    }
}

extension DevelopRenderer {
    /// The camera match for a RAW file, measured once per file version and kept for the session.
    func cameraMatch(for url: URL) -> CameraMatch {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cameraMatches.object(forKey: key) { return cached.match }
        let match = CameraMatch.measure(url: url, context: context) ?? .identity
        cameraMatches.setObject(CameraMatchBox(match), forKey: key)
        return match
    }
}

final class CameraMatchBox: NSObject {
    let match: CameraMatch
    init(_ match: CameraMatch) { self.match = match }
}
