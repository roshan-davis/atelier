import CoreGraphics
import CoreML
import Foundation

/// One face's expression, from Google's MediaPipe Face Landmarker (0...1 each, the ARKit
/// blendshape scores): how closed each eye is, how squinted, how much the mouth smiles.
public struct FaceExpression: Sendable, Equatable {
    public var blinkLeft: Double
    public var blinkRight: Double
    public var squintLeft: Double
    public var squintRight: Double
    public var smileLeft: Double
    public var smileRight: Double

    public init(blinkLeft: Double, blinkRight: Double, squintLeft: Double = 0, squintRight: Double = 0,
                smileLeft: Double = 0, smileRight: Double = 0) {
        self.blinkLeft = blinkLeft
        self.blinkRight = blinkRight
        self.squintLeft = squintLeft
        self.squintRight = squintRight
        self.smileLeft = smileLeft
        self.smileRight = smileRight
    }

    public var blink: Double { (blinkLeft + blinkRight) / 2 }
    public var smile: Double { (smileLeft + smileRight) / 2 }
}

/// Google's MediaPipe Face Landmarker (Face Mesh V2 and Blendshape V2, Apache License 2.0),
/// converted to Core ML by `Scripts/models/convert_mediapipe_face_landmarker.py` and built into
/// the app (Models/FaceMesh.mlpackage and FaceBlendshapes.mlpackage, about 4.5 MB together).
/// Cull's Advanced checks run it on each face Vision found: the mesh model places 478 points on
/// a 256 px crop of the face, and the blendshape model turns 146 of them into 52 expression
/// scores, of which Cull reads blinks, squints and smiles. Google's own face detector isn't used:
/// Vision has already found the faces.
public enum FaceLandmarker {
    /// The version is the first 12 hex digits of the .task file's SHA-256.
    static let mesh = BundledModel(name: "FaceMesh", version: "64184e229b26")
    static let blendshapes = BundledModel(name: "FaceBlendshapes", version: "64184e229b26")

    /// The mesh model's square input size.
    public static let size = 256
    /// The crop is this many times the face box's larger side, about what Google's own pipeline
    /// gives the mesh model (checked on the Cull test photos: 1.3 to 1.8 read the same).
    public static let cropScale = 1.5

    /// Whether both models are in the app and load.
    public static var isAvailable: Bool { mesh.isAvailable && blendshapes.isAvailable }

    /// The mesh points the blendshape model reads (Google's subset, in its order).
    static let subset: [Int] = [
        0, 1, 4, 5, 6, 7, 8, 10, 13, 14, 17, 21, 33, 37, 39, 40, 46, 52, 53, 54,
        55, 58, 61, 63, 65, 66, 67, 70, 78, 80, 81, 82, 84, 87, 88, 91, 93, 95, 103, 105,
        107, 109, 127, 132, 133, 136, 144, 145, 146, 148, 149, 150, 152, 153, 154, 155, 157, 158, 159, 160,
        161, 162, 163, 168, 172, 173, 176, 178, 181, 185, 191, 195, 197, 234, 246, 249, 251, 263, 267, 269,
        270, 276, 282, 283, 284, 285, 288, 291, 293, 295, 296, 297, 300, 308, 310, 311, 312, 314, 317, 318,
        321, 323, 324, 332, 334, 336, 338, 356, 361, 362, 365, 373, 374, 375, 377, 378, 379, 380, 381, 382,
        384, 385, 386, 387, 388, 389, 390, 397, 398, 400, 402, 405, 409, 415, 454, 466, 468, 469, 470, 471,
        472, 473, 474, 475, 476, 477,
    ]

    // Blendshape indices (ARKit names, Google's order).
    static let eyeBlinkLeft = 9, eyeBlinkRight = 10, eyeSquintLeft = 19, eyeSquintRight = 20
    static let mouthSmileLeft = 44, mouthSmileRight = 45

    /// The expression of the face in `box` (Vision's rectangle: 0...1, origin bottom left) of
    /// `image`; nil when the models aren't available, or the mesh model says there's no face
    /// there (Vision found something that isn't one).
    public static func expression(in image: CGImage, box: CGRect) -> FaceExpression? {
        guard let input = crop(image, box: box), let points = landmarks(input) else { return nil }
        return expression(points: points)
    }

    /// The crop the mesh model reads: a square `cropScale` times the face's larger side, centred
    /// on it, `size` px, RGB 0...1, rows from the top (1 × 256 × 256 × 3). Outside the photo is black,
    /// as in Google's pipeline.
    static func crop(_ image: CGImage, box: CGRect) -> [Float]? {
        let width = Double(image.width), height = Double(image.height)
        // The face in pixels, top-left origin.
        let face = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        let side = max(face.width, face.height) * cropScale
        guard side >= 8 else { return nil }
        let square = CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side)
        let inside = square.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard inside.width >= 4, inside.height >= 4, let part = image.cropping(to: inside),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let scale = Double(size) / side
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .high
        // The context's origin is bottom left: the part's top edge lands (inside.minY - square.minY)
        // below the crop's top.
        context.draw(part, in: CGRect(x: (inside.minX - square.minX) * scale,
                                      y: Double(size) - (inside.maxY - square.minY) * scale,
                                      width: inside.width * scale, height: inside.height * scale))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        // CGContext's memory starts at the top row.
        var out = [Float](repeating: 0, count: size * size * 3)
        for pixel in 0..<(size * size) {
            for c in 0..<3 { out[pixel * 3 + c] = Float(bytes[pixel * 4 + c]) / 255 }
        }
        return out
    }

    /// The 478 mesh points (x, y, z; x and y in the crop's pixels) for a crop, or nil without a
    /// face (the model's face logit below 0, under even odds).
    static func landmarks(_ input: [Float]) -> [Float]? {
        guard let model = mesh.model(),
              let array = try? MLMultiArray(shape: [1, NSNumber(value: size), NSNumber(value: size), 3], dataType: .float32)
        else { return nil }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        input.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: input.count) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: array)]),
              let output = try? model.prediction(from: provider),
              let points = output.featureValue(for: "landmarks")?.multiArrayValue,
              let face = output.featureValue(for: "face")?.multiArrayValue else { return nil }
        let values = BundledModel.floats(points)
        guard values.count == 478 * 3, let logit = BundledModel.floats(face).first, logit > 0 else { return nil }
        return values
    }

    /// The expression from the mesh points.
    static func expression(points: [Float]) -> FaceExpression? {
        guard points.count == 478 * 3, let model = blendshapes.model(),
              let array = try? MLMultiArray(shape: [1, NSNumber(value: subset.count), 2], dataType: .float32)
        else { return nil }
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: subset.count * 2)
        for (i, index) in subset.enumerated() {
            pointer[i * 2] = points[index * 3]
            pointer[i * 2 + 1] = points[index * 3 + 1]
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["points": MLFeatureValue(multiArray: array)]),
              let output = try? model.prediction(from: provider),
              let scores = output.featureValue(for: "blendshapes")?.multiArrayValue else { return nil }
        let s = BundledModel.floats(scores).map(Double.init)
        guard s.count == 52 else { return nil }
        return FaceExpression(blinkLeft: s[eyeBlinkLeft], blinkRight: s[eyeBlinkRight],
                              squintLeft: s[eyeSquintLeft], squintRight: s[eyeSquintRight],
                              smileLeft: s[mouthSmileLeft], smileRight: s[mouthSmileRight])
    }
}
