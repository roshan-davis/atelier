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
    /// The best face's capture quality (0...1; eyes open, in focus); nil without faces. Only
    /// Pick By Classic uses it; the others read each face (`faces`).
    public var faceQuality: Double?
    /// A small picture for the Cull view.
    public var thumbnail: CGImage?
    /// The picture's brightness on a `Culling.layoutSize` square grid, for comparing framing
    /// pixel by pixel; nil when the file can't be read.
    public var layout: [Float]?
    /// Width over height.
    public var aspect: Float
    /// Every face Vision found, with eye openness and sharpness.
    public var faces: [CullFace]
    /// Sharpness where the subject is: the faces (weighted by size), else Vision's most
    /// salient object, else the whole frame. Same scale as `sharpness`.
    public var subjectSharpness: Double
    /// How much the subject's edges run one way (`GrayPlane.edgeCoherence`), to tell motion
    /// blur from missed focus.
    public var coherence: Double
    public var exposure: CullExposure
    /// Apple's aesthetics score (-1...1); nil where Vision can't give one.
    public var aesthetics: Double?
    /// Apple's "utility" label: screenshots, receipts, documents.
    public var isUtility: Bool
    /// The Advanced checks ran (eyes read from a large copy).
    public var advanced: Bool

    public init(featurePrint: VNFeaturePrintObservation? = nil, sharpness: Double = 0, faceQuality: Double? = nil,
                thumbnail: CGImage? = nil, layout: [Float]? = nil, aspect: Float = 1.5, faces: [CullFace] = [],
                subjectSharpness: Double? = nil, coherence: Double = 0, exposure: CullExposure = CullExposure(),
                aesthetics: Double? = nil, isUtility: Bool = false, advanced: Bool = false) {
        self.featurePrint = featurePrint
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.thumbnail = thumbnail
        self.layout = layout
        self.aspect = aspect
        self.faces = faces
        self.subjectSharpness = subjectSharpness ?? sharpness
        self.coherence = coherence
        self.exposure = exposure
        self.aesthetics = aesthetics
        self.isUtility = isUtility
        self.advanced = advanced
    }

    /// Eye sharpness from the Advanced checks: the faces' eyes, weighted by face size; nil when
    /// they didn't run or found no eyes.
    public var eyeSharpness: Double? {
        let read = faces.filter { $0.eyeSharpness != nil }
        guard advanced, !read.isEmpty else { return nil }
        let weight = read.reduce(0) { $0 + $1.box.width }
        guard weight > 0 else { return nil }
        return read.reduce(0) { $0 + $1.eyeSharpness! * $1.box.width } / weight
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
    /// Reads a photo at 1024 px (the embedded preview for RAW files) and measures it: what
    /// grouping needs (feature print, layout) and what picking needs (sharpness on the subject,
    /// faces and their eyes, exposure, Apple's aesthetics score).
    public static func analyze(_ url: URL) async -> CullSignals {
        guard let image = image(at: url, maxPixel: 1024) else { return CullSignals() }
        let plane = GrayPlane(image)
        var signals = CullSignals(sharpness: plane?.laplacianVariance() ?? 0, thumbnail: scaled(image, maxPixel: 320),
                                  layout: layout(of: image), aspect: Float(image.width) / Float(max(image.height, 1)))
        let print = VNGenerateImageFeaturePrintRequest()
        let landmarks = VNDetectFaceLandmarksRequest()
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([print, landmarks, saliency])
        signals.featurePrint = print.results?.first
        // Capture quality for the same faces, so each face has both.
        let found = landmarks.results ?? []
        var qualities: [VNFaceObservation] = []
        if !found.isEmpty {
            let quality = VNDetectFaceCaptureQualityRequest()
            quality.inputFaceObservations = found
            try? handler.perform([quality])
            qualities = quality.results ?? []
        }
        let size = CGSize(width: image.width, height: image.height)
        signals.faces = found.map { observation in
            var face = CullFaceReading.face(observation, imageSize: size, plane: plane)
            let match = qualities.min { distance($0.boundingBox, observation.boundingBox) < distance($1.boundingBox, observation.boundingBox) }
            face.quality = match?.faceCaptureQuality.map(Double.init)
            return face
        }
        signals.faceQuality = signals.faces.compactMap(\.quality).max()
        if let plane {
            let subject = subjectRect(faces: signals.faces, saliency: saliency.results?.first, plane: plane)
            signals.subjectSharpness = subjectSharpness(faces: signals.faces, fallback: plane.laplacianVariance(in: subject))
            signals.coherence = plane.edgeCoherence(in: subject)
            signals.exposure = plane.exposure()
        }
        if let scores = try? await CalculateImageAestheticsScoresRequest().perform(on: image) {
            signals.aesthetics = Double(scores.overallScore)
            signals.isUtility = scores.isUtility
        }
        return signals
    }

    /// The Advanced checks for one photo: reads a large copy (up to `maxPixel`, three to four
    /// times the standard size) and, for each face found before, reads the eyes again there:
    /// openness for faces too small to judge before, and the eyes' sharpness at real detail.
    public static func analyzeAdvanced(_ url: URL, signals: CullSignals, maxPixel: Int = 4096) -> CullSignals {
        var result = signals
        result.advanced = true
        guard !signals.faces.isEmpty, let image = image(at: url, maxPixel: maxPixel) else { return result }
        let width = Double(image.width), height = Double(image.height)
        result.faces = signals.faces.map { face in
            var face = face
            // The face with room around it, in pixels (CGImage cropping is top-left based).
            let margin = face.box.width * 0.4
            let box = face.box.insetBy(dx: -margin, dy: -margin)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let crop = CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                              width: box.width * width, height: box.height * height).integral
            guard crop.width >= 32, crop.height >= 32, let cropped = image.cropping(to: crop) else { return face }
            let request = VNDetectFaceLandmarksRequest()
            try? VNImageRequestHandler(cgImage: cropped).perform([request])
            // The face nearest the middle of the crop is this one.
            guard let found = request.results?.min(by: {
                hypot($0.boundingBox.midX - 0.5, $0.boundingBox.midY - 0.5) < hypot($1.boundingBox.midX - 0.5, $1.boundingBox.midY - 0.5)
            }) else { return face }
            let size = CGSize(width: cropped.width, height: cropped.height)
            // A face that was too small is judged now; its size here is what counts.
            let read = CullFaceReading.face(found, imageSize: size, plane: nil, minimumPixels: 0)
            if face.openness == nil || face.skip == .small {
                face.openness = read.openness
                face.skip = read.skip
            }
            if let eyes = CullFaceReading.eyeRegion(found, imageSize: size), let plane = GrayPlane(cropped, maxPixel: 4096) {
                face.eyeSharpness = plane.laplacianVariance(in: plane.pixelRect(fromVision: eyes))
            }
            return face
        }
        // Blinks and smiles from MediaPipe Face Landmarker, on the same large copy.
        result.faces = result.faces.map { face in
            var face = face
            face.expression = FaceLandmarker.expression(in: image, box: face.box)
            return face
        }
        return result
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    /// Where the subject is, in `plane`'s pixels: around the faces, else Vision's most salient
    /// object, else the whole frame.
    static func subjectRect(faces: [CullFace], saliency: VNSaliencyImageObservation?, plane: GrayPlane) -> CGRect {
        let judged = faces.filter { $0.box.width * Double(plane.width) >= 24 }
        if let first = judged.first {
            let union = judged.dropFirst().reduce(first.box) { $0.union($1.box) }
            return plane.pixelRect(fromVision: union)
        }
        if let objects = saliency?.salientObjects,
           let biggest = objects.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
           biggest.boundingBox.width * biggest.boundingBox.height < 0.9 {
            return plane.pixelRect(fromVision: biggest.boundingBox)
        }
        return plane.bounds
    }

    /// The faces' sharpness weighted by their size (bigger faces are what the photo is of);
    /// `fallback` without faces big enough to read.
    static func subjectSharpness(faces: [CullFace], fallback: Double) -> Double {
        let read = faces.filter { $0.sharpness != nil && $0.skip != .small }
        let weight = read.reduce(0) { $0 + $1.box.width }
        guard weight > 0 else { return fallback }
        return read.reduce(0) { $0 + $1.sharpness! * $1.box.width } / weight
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
        // The same frame also has to line up as a whole and, where Vision can tell, look alike:
        // two flat, different scenes can differ in few places.
        let lookAlike = comparison.featureDistance.map { $0 <= featureThreshold(looseness: looseness) * widen } ?? true
        let linesUp = comparison.aligned.map { $0 <= (0.10 + 0.25 * loose) * widen } ?? true
        if let change = comparison.frameChange, change <= (0.06 + 0.16 * loose) * widen, lookAlike, linesUp {
            return .sameFrame
        }
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

    /// A photo's size in pixels as it is seen (turned upright by its EXIF orientation), without
    /// decoding it; nil when the file can't be read.
    public static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // Orientations 5 to 8 turn the picture a quarter.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

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

    /// Variance of the Laplacian of the gray image at 1024 px: blur and missed focus lower it.
    public static func sharpness(of image: CGImage) -> Double {
        GrayPlane(image)?.laplacianVariance() ?? 0
    }
}
