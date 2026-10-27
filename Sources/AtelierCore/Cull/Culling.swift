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
    /// The picture's brightness on a `Culling.layoutSize` square grid, for comparing framing
    /// pixel by pixel; nil when the file can't be read.
    public var layout: [Float]?
    /// Width over height.
    public var aspect: Float

    public init(featurePrint: VNFeaturePrintObservation? = nil, sharpness: Double = 0, faceQuality: Double? = nil,
                thumbnail: CGImage? = nil, layout: [Float]? = nil, aspect: Float = 1.5) {
        self.featurePrint = featurePrint
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.thumbnail = thumbnail
        self.layout = layout
        self.aspect = aspect
    }
}

/// How culling groups shots.
public enum CullMode: String, CaseIterable, Identifiable, Sendable {
    /// The same frame from the same spot: only people moving a little, blinks, expressions.
    case sameFrame
    /// Also the same scene reframed: a slight zoom or step, people in the background moving,
    /// focus on a different subject. Bursts always count.
    case similarShots

    public var id: String { rawValue }
}

/// What `Culling.compare` measured between two shots; nil where it couldn't.
public struct CullComparison: Sendable, Equatable {
    /// `Culling.frameChange`, when both are framed the same way round.
    public var frameChange: Float?
    /// `Culling.alignedDifference`.
    public var aligned: Float?
    /// Vision feature-print distance.
    public var featureDistance: Float?
    /// Both could be read.
    public var readable = false

    public init(frameChange: Float? = nil, aligned: Float? = nil, featureDistance: Float? = nil, readable: Bool = false) {
        self.frameChange = frameChange
        self.aligned = aligned
        self.featureDistance = featureDistance
        self.readable = readable
    }
}

/// How two neighboring shots relate.
public enum CullLink: Sendable, Equatable {
    /// Same framing; only a small part of the picture changed.
    case sameFrame
    /// The same scene, reframed, refocused or with things moving.
    case similarShot
    case different
    /// Neither photo could be read.
    case unknown
}

public enum Culling {
    /// Reads a photo at 1024 px (the embedded preview for RAW files) and measures it.
    public static func analyze(_ url: URL) -> CullSignals {
        guard let image = image(at: url, maxPixel: 1024) else { return CullSignals() }
        var signals = CullSignals(sharpness: sharpness(of: image), thumbnail: scaled(image, maxPixel: 320),
                                  layout: layout(of: image), aspect: Float(image.width) / Float(max(image.height, 1)))
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

    /// Feature-print distance two photos may be apart and still be similar shots, for a
    /// Grouping slider position (0 tight, 1 loose).
    public static func featureThreshold(looseness: Double) -> Float { Float(0.35 + looseness * 0.5) }

    /// Measures how alike two shots are. Lining them up for a zoom (`alignedDifference`) is
    /// the slow part; `aligning: false` skips it.
    public static func compare(_ a: CullSignals, _ b: CullSignals, aligning: Bool = true) -> CullComparison {
        var comparison = CullComparison()
        if let first = a.layout, let second = b.layout {
            comparison.readable = true
            if abs(a.aspect - b.aspect) < 0.05 {
                comparison.frameChange = frameChange(first, second)
                if aligning { comparison.aligned = alignedDifference(first, second) }
            }
        }
        comparison.featureDistance = distance(a, b)
        if comparison.featureDistance != nil { comparison.readable = true }
        return comparison
    }

    /// How two shots relate at a Grouping slider position (0 tight, 1 loose). `slack` widens
    /// every limit by half, for comparing a shot with the first of its group, not its neighbor.
    public static func link(_ comparison: CullComparison, looseness: Double, slack: Bool = false) -> CullLink {
        let widen: Float = slack ? 1.5 : 1
        let loose = Float(looseness)
        if let change = comparison.frameChange, change <= (0.08 + 0.22 * loose) * widen { return .sameFrame }
        if let aligned = comparison.aligned, aligned <= (0.10 + 0.25 * loose) * widen { return .similarShot }
        if let distance = comparison.featureDistance, distance <= featureThreshold(looseness: looseness) * widen {
            return .similarShot
        }
        return comparison.readable ? .different : .unknown
    }

    /// Splits photos (already in capture order) into groups of similar shots. A photo joins the
    /// group before it when it was taken within `maxGap` seconds of the previous photo and
    /// `link` says it matches both that photo and, with slack, the group's first (so a slow pan
    /// doesn't chain a whole shoot). In `.sameFrame` mode only same-frame links count; in
    /// `.similarShots` similar shots count too and shots under a second apart are a burst and
    /// always join. Photos neither of which can be read join when two seconds apart or less.
    public static func groups(count: Int, times: (Int) -> Date?, mode: CullMode = .similarShots,
                              maxGap: TimeInterval = 60, link: (_ a: Int, _ b: Int, _ slack: Bool) -> CullLink) -> [[Int]] {
        var groups: [[Int]] = []
        let accepted: Set<CullLink> = mode == .sameFrame ? [.sameFrame] : [.sameFrame, .similarShot]
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
            } else if mode == .similarShots, let gap, gap < 1 {
                joins = true
            } else {
                switch link(previous, index, false) {
                case .unknown:
                    joins = gap.map { $0 <= 2 } ?? false
                case let near where accepted.contains(near):
                    let fromFirst = first == previous ? near : link(first, index, true)
                    joins = accepted.contains(fromFirst) || fromFirst == .unknown
                default:
                    joins = false
                }
            }
            if joins { groups[groups.count - 1].append(index) } else { groups.append([index]) }
        }
        return groups
    }

    /// Groups by feature-print distance alone: a photo joins when `distance` is at most
    /// `threshold` from its neighbor and 1.5 × `threshold` from the group's first shot.
    public static func groups(count: Int, times: (Int) -> Date?, distance: (Int, Int) -> Float?,
                              threshold: Float, maxGap: TimeInterval = 60) -> [[Int]] {
        groups(count: count, times: times, maxGap: maxGap) { a, b, slack in
            guard let value = distance(a, b) else { return .unknown }
            return value <= threshold * (slack ? 1.5 : 1) ? .similarShot : .different
        }
    }

    // MARK: Comparing framing

    /// The side of the brightness grid kept for each photo.
    public static let layoutSize = 64

    /// The picture's brightness (0...1) squeezed onto a `layoutSize` square.
    public static func layout(of image: CGImage) -> [Float]? {
        let side = layoutSize
        var gray = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &gray, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return gray.map { Float($0) / 255 }
    }

    /// The share of the picture (0...1) that changed between two shots framed the same way:
    /// a blink or a turned head changes a few percent, a step to the side most of it. Exposure
    /// differences don't count, and a shift of one cell (about 3% of the frame) is forgiven.
    public static func frameChange(_ a: [Float], _ b: [Float]) -> Float {
        let side = 32
        let first = standardized(sample(a, side: side, crop: (0.5, 0.5, 1)))
        let second = standardized(sample(b, side: side, crop: (0.5, 0.5, 1)))
        var best: Float = 1
        for dy in -1...1 {
            for dx in -1...1 {
                var changed = 0, cells = 0
                for y in 1..<(side - 1) {
                    for x in 1..<(side - 1) {
                        cells += 1
                        if abs(first[y * side + x] - second[(y + dy) * side + x + dx]) > 0.75 { changed += 1 }
                    }
                }
                best = min(best, Float(changed) / Float(cells))
            }
        }
        return best
    }

    /// How different two shots look (0 identical, 1 unrelated) once one is zoomed and shifted
    /// to line up with the other, allowing about a quarter's zoom: the same scene from a step
    /// closer, or recomposed a little.
    public static func alignedDifference(_ a: [Float], _ b: [Float]) -> Float {
        let side = 24
        var best: Float = 1
        for (wide, tight) in [(a, b), (b, a)] {
            let target = standardized(sample(tight, side: side, crop: (0.5, 0.5, 1)))
            for scale in [Float(1), 0.92, 0.85, 0.78] {
                let room = (1 - scale) / 2
                let steps: [Float] = room > 0 ? [-room, 0, room] : [0]
                for oy in steps {
                    for ox in steps {
                        let candidate = standardized(sample(wide, side: side, crop: (0.5 + ox, 0.5 + oy, scale)))
                        var dot: Float = 0
                        for i in 0..<candidate.count { dot += candidate[i] * target[i] }
                        // 1 - correlation, as a share of how far apart unrelated pictures are.
                        best = min(best, max(0, 1 - dot / Float(candidate.count)))
                    }
                }
            }
        }
        return best
    }

    /// Resamples a layout's square `crop` (center x, center y, side, all as shares of the
    /// frame) onto a `side` grid.
    static func sample(_ layout: [Float], side: Int, crop: (Float, Float, Float)) -> [Float] {
        let source = Int(Double(layout.count).squareRoot())
        guard source > 1 else { return [Float](repeating: 0, count: side * side) }
        var result = [Float](repeating: 0, count: side * side)
        let extent = crop.2 * Float(source)
        let originX = crop.0 * Float(source) - extent / 2, originY = crop.1 * Float(source) - extent / 2
        for y in 0..<side {
            for x in 0..<side {
                let sx = min(max(originX + (Float(x) + 0.5) * extent / Float(side) - 0.5, 0), Float(source - 1))
                let sy = min(max(originY + (Float(y) + 0.5) * extent / Float(side) - 0.5, 0), Float(source - 1))
                let x0 = Int(sx), y0 = Int(sy)
                let x1 = min(x0 + 1, source - 1), y1 = min(y0 + 1, source - 1)
                let fx = sx - Float(x0), fy = sy - Float(y0)
                let top = layout[y0 * source + x0] * (1 - fx) + layout[y0 * source + x1] * fx
                let bottom = layout[y1 * source + x0] * (1 - fx) + layout[y1 * source + x1] * fx
                result[y * side + x] = top * (1 - fy) + bottom * fy
            }
        }
        return result
    }

    /// Zero mean, unit spread, so brighter and darker takes of one scene match. Flat pictures
    /// keep a floor on the spread so noise isn't blown up into detail.
    static func standardized(_ values: [Float]) -> [Float] {
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        let spread = max(variance.squareRoot(), 0.02)
        return values.map { ($0 - mean) / spread }
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
