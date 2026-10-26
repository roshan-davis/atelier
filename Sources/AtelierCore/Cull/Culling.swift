import CoreGraphics
import Foundation
import ImageIO
import Vision

/// What culling learns about one photo.
public struct CullSignals: @unchecked Sendable {
    /// Vision's description of the picture, for "looks alike"; nil when Vision can't run.
    public var featurePrint: VNFeaturePrintObservation?
    /// Variance of the Laplacian on a 1024 px copy: higher is sharper. Only comparable
    /// between photos of the same scene.
    public var sharpness: Double
    /// The best face's capture quality (0...1; eyes open, in focus); nil without faces.
    public var faceQuality: Double?
    /// A small picture for the Cull view.
    public var thumbnail: CGImage?

    public init(featurePrint: VNFeaturePrintObservation? = nil, sharpness: Double = 0, faceQuality: Double? = nil,
                thumbnail: CGImage? = nil) {
        self.featurePrint = featurePrint
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.thumbnail = thumbnail
    }
}

public enum Culling {
    /// Reads a photo at 1024 px (the embedded preview for RAW files) and measures it.
    public static func analyze(_ url: URL) -> CullSignals {
        guard let image = image(at: url, maxPixel: 1024) else { return CullSignals() }
        var signals = CullSignals(sharpness: sharpness(of: image), thumbnail: scaled(image, maxPixel: 320))
        let print = VNGenerateImageFeaturePrintRequest()
        let faces = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([print, faces])
        signals.featurePrint = print.results?.first
        signals.faceQuality = faces.results?.compactMap { $0.faceCaptureQuality.map(Double.init) }.max()
        return signals
    }

    /// How different two photos look; 0 is identical. nil when either has no feature print.
    public static func distance(_ a: CullSignals, _ b: CullSignals) -> Float? {
        guard let first = a.featurePrint, let second = b.featurePrint else { return nil }
        var distance: Float = 0
        do {
            try first.computeDistance(&distance, to: second)
        } catch {
            return nil
        }
        return distance
    }

    /// Splits photos (already in capture order) into groups of similar shots. A photo joins the
    /// group before it when it was taken within `maxGap` seconds of the previous photo and looks
    /// like it (`distance` at most `threshold`); shots under a second apart are a burst and
    /// always join. Without a capture time, only looks count.
    public static func groups(count: Int, times: (Int) -> Date?, distance: (Int, Int) -> Float?,
                              threshold: Float, maxGap: TimeInterval = 60) -> [[Int]] {
        var groups: [[Int]] = []
        for index in 0..<count {
            guard let previous = groups.last?.last, let first = groups.last?.first else {
                groups.append([index])
                continue
            }
            var gap: TimeInterval?
            if let now = times(index), let before = times(previous) { gap = abs(now.timeIntervalSince(before)) }
            let joins: Bool
            if let gap, gap > maxGap {
                joins = false
            } else if let gap, gap < 1 {
                joins = true
            } else if let near = distance(previous, index) {
                // Compare with the group's first shot too, so a slow pan doesn't chain a whole shoot.
                let fromFirst = distance(first, index) ?? near
                joins = near <= threshold && fromFirst <= threshold * 1.5
            } else {
                joins = gap.map { $0 <= 2 } ?? false
            }
            if joins { groups[groups.count - 1].append(index) } else { groups.append([index]) }
        }
        return groups
    }

    /// The photo to suggest keeping in a group: the sharpest, with face quality counting as
    /// much when the group has faces.
    public static func suggestedKeeper(_ signals: [CullSignals]) -> Int? {
        guard !signals.isEmpty else { return nil }
        let maxSharpness = max(signals.map(\.sharpness).max() ?? 0, .leastNonzeroMagnitude)
        let hasFaces = signals.contains { $0.faceQuality != nil }
        let scores = signals.map { signal -> Double in
            var score = signal.sharpness / maxSharpness
            if hasFaces { score += signal.faceQuality ?? 0 }
            return score
        }
        return scores.indices.max { scores[$0] < scores[$1] }
    }

    // MARK: Measuring

    public static func image(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Variance of the Laplacian of the gray image: blur and missed focus lower it.
    public static func sharpness(of image: CGImage) -> Double {
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let width = max(3, Int(Double(image.width) * scale)), height = max(3, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0, sumSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let center = Double(gray[row + x]) * 4
                let around = Double(gray[row + x - 1]) + Double(gray[row + x + 1])
                    + Double(gray[row - width + x]) + Double(gray[row + width + x])
                let value = around - center
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }
}
