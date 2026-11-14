import CoreGraphics
import CoreML
import Foundation

/// Which face finder Cull uses (the Cull view's Find Faces menu). Named after the algorithm,
/// not ranked: either can improve with a release (Rosh, Nov 14, 2026).
public enum CullFaceFinder: String, CaseIterable, Identifiable, Sendable {
    /// Apple's Vision face detector, as before Nov 14, 2026.
    case vision
    /// Google's MediaPipe face detector (BlazeFace): on the whole frame and inside each person
    /// Vision's body detector found.
    case mediaPipe
    /// Vision's faces, plus MediaPipe's inside any person Vision found no face for. The default.
    case both

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vision: return "Apple Vision"
        case .mediaPipe: return "MediaPipe"
        case .both: return "Both"
        }
    }

    public var help: String {
        switch self {
        case .vision: return "Apple's face detector, built into macOS"
        case .mediaPipe: return "Google's MediaPipe face detector (BlazeFace), built into Atelier, looking inside each person found"
        case .both: return "Apple Vision first, then MediaPipe inside any person Vision found no face for"
        }
    }
}

/// Google's MediaPipe face detector, BlazeFace short range (Apache License 2.0, from the Face
/// Landmarker task), converted to Core ML by `Scripts/models/convert_mediapipe_face_landmarker.py`
/// and built into the app (Models/FaceDetector.mlpackage, about 0.3 MB). It reads a 128 px
/// square, so faces must be a few percent of what it is given: Cull runs it on the whole frame
/// and on the top half of each person Vision's body detector found, where it found a face behind
/// sunglasses down to 24 px in a 1024 px frame (checked against Google's own runtime, Nov 14, 2026).
public enum FaceDetector {
    static let model = BundledModel(name: "FaceDetector", version: "64184e229b26")
    /// The model's square input size.
    static let size = 128
    /// Faces scoring under this (0...1) are dropped, as in Google's pipeline.
    public static let minimumScore = 0.5

    public static var isAvailable: Bool { model.isAvailable }

    /// The anchor centers (0...1, rows from the top), in the model's output order: a 16 × 16
    /// grid with 2 per cell, then an 8 × 8 grid with 6 per cell.
    static let anchors: [CGPoint] = {
        var out: [CGPoint] = []
        for (grid, perCell) in [(16, 2), (8, 6)] {
            for y in 0..<grid {
                for x in 0..<grid {
                    let point = CGPoint(x: (Double(x) + 0.5) / Double(grid), y: (Double(y) + 0.5) / Double(grid))
                    out.append(contentsOf: repeatElement(point, count: perCell))
                }
            }
        }
        return out
    }()

    /// The faces in `region` of `image` (both as Vision rectangles: 0...1, origin bottom left),
    /// with their scores, in the whole image's Vision coordinates.
    public static func faces(in image: CGImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1))
        -> [(box: CGRect, score: Double)] {
        let width = Double(image.width), height = Double(image.height)
        // All in Double, step by step: mixed CGFloat/Double sums are slow to type-check.
        let regionX = Double(region.minX) * width
        let regionY = (1 - Double(region.maxY)) * height
        let regionW = Double(region.width) * width
        let regionH = Double(region.height) * height
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        let pixels = CGRect(x: regionX, y: regionY, width: regionW, height: regionH).intersection(whole).integral
        guard pixels.width >= 8, pixels.height >= 8, let part = image.cropping(to: pixels),
              let input = letterbox(part) else { return [] }
        let side = Double(max(pixels.width, pixels.height))
        let originX = Double(pixels.minX), originY = Double(pixels.minY)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var out: [(box: CGRect, score: Double)] = []
        for found in run(input) {
            // Square coordinates (top-left) to the image's pixels, then to Vision's.
            let x: Double = originX + Double(found.box.minX) * side
            let y: Double = originY + Double(found.box.minY) * side
            let w: Double = Double(found.box.width) * side
            let h: Double = Double(found.box.height) * side
            let box = CGRect(x: x / width, y: 1 - (y + h) / height, width: w / width, height: h / height)
            out.append((box: box.intersection(unit), score: found.score))
        }
        return out
    }

    /// `image` scaled into the top-left of a black 128 px square, RGB -1...1, rows from the top.
    static func letterbox(_ image: CGImage) -> [Float]? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let scale: Double = Double(size) / Double(max(image.width, image.height))
        let drawnWidth: Double = Double(image.width) * scale
        let drawnHeight: Double = Double(image.height) * scale
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .high
        // The context's origin is bottom left: put the picture against the top edge.
        context.draw(image, in: CGRect(x: 0, y: Double(size) - drawnHeight, width: drawnWidth, height: drawnHeight))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var out = [Float](repeating: 0, count: size * size * 3)
        for pixel in 0..<(size * size) {
            for c in 0..<3 { out[pixel * 3 + c] = Float(bytes[pixel * 4 + c]) / 127.5 - 1 }
        }
        return out
    }

    /// The model on one input; boxes in the square's 0...1 coordinates (top-left).
    static func run(_ input: [Float]) -> [(box: CGRect, score: Double)] {
        guard let network = Self.model.model(),
              let array = try? MLMultiArray(shape: [1, NSNumber(value: size), NSNumber(value: size), 3], dataType: .float32)
        else { return [] }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        input.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: input.count) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: array)]),
              let output = try? network.prediction(from: provider),
              let regressors = output.featureValue(for: "regressors")?.multiArrayValue,
              let logits = output.featureValue(for: "classificators")?.multiArrayValue else { return [] }
        return decode(regressors: BundledModel.floats(regressors), logits: BundledModel.floats(logits))
    }

    /// Boxes from the model's outputs: each anchor's offsets (in input pixels) and logit, best
    /// first, overlapping boxes (IoU 0.3 or more) dropped.
    static func decode(regressors: [Float], logits: [Float], threshold: Double = FaceDetector.minimumScore)
        -> [(box: CGRect, score: Double)] {
        guard regressors.count == anchors.count * 16, logits.count == anchors.count else { return [] }
        let n = Double(size)
        var found: [(box: CGRect, score: Double)] = []
        for (i, anchor) in anchors.enumerated() {
            let logit: Double = Double(max(-80, min(80, logits[i])))
            let score: Double = 1 / (1 + exp(-logit))
            guard score >= threshold else { continue }
            let r = i * 16
            let cx: Double = Double(regressors[r]) / n + Double(anchor.x)
            let cy: Double = Double(regressors[r + 1]) / n + Double(anchor.y)
            let w: Double = Double(regressors[r + 2]) / n
            let h: Double = Double(regressors[r + 3]) / n
            guard w > 0, h > 0 else { continue }
            found.append((box: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), score: score))
        }
        return suppress(found)
    }

    /// Best first, without boxes overlapping a better one (IoU 0.3 or more).
    static func suppress(_ boxes: [(box: CGRect, score: Double)]) -> [(box: CGRect, score: Double)] {
        var kept: [(box: CGRect, score: Double)] = []
        for candidate in boxes.sorted(by: { $0.score > $1.score })
            where !kept.contains(where: { overlap($0.box, candidate.box) >= 0.3 }) {
            kept.append(candidate)
        }
        return kept
    }

    /// Intersection over union.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let common = a.intersection(b)
        guard !common.isNull else { return 0 }
        let shared: Double = Double(common.width * common.height)
        let areaA: Double = Double(a.width * a.height)
        let areaB: Double = Double(b.width * b.height)
        let union: Double = areaA + areaB - shared
        return union > 0 ? shared / union : 0
    }

    /// Where to look for a face in a person Vision's body detector found: the top half of the
    /// body box (Vision rectangle), squared up a little so a head isn't cut at the sides.
    static func headRegion(of person: CGRect) -> CGRect {
        let top = CGRect(x: person.minX, y: person.midY, width: person.width, height: person.height / 2)
        let margin: CGFloat = top.width * 0.1
        return top.insetBy(dx: -margin, dy: 0).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// MediaPipe's faces in `image`: on the whole frame and inside each of `people` (Vision
    /// rectangles), one box per face.
    static func faces(in image: CGImage, people: [CGRect]) -> [CGRect] {
        var found = faces(in: image)
        for person in people {
            found += faces(in: image, region: headRegion(of: person))
        }
        return suppress(found).map { $0.box }
    }
}
