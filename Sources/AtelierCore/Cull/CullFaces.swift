import CoreGraphics
import Foundation
import Vision

/// One face in a photo, as culling reads it.
public struct CullFace: Sendable, Equatable {
    /// Where the face is, as Vision gives it (0...1, origin bottom left).
    public var box: CGRect
    /// Vision's capture quality (0...1; light, focus, pose and open eyes mixed in one number).
    public var quality: Double?
    /// Eye openness: the eye outline's height over its width, the mean of both eyes (the "eye
    /// aspect ratio"; Soukupová & Čech 2016). nil when the eyes weren't judged (`skip`).
    public var openness: Double?
    /// Why the eyes weren't judged; nil when they were.
    public var skip: CullFaceSkip?
    /// Sharpness (variance of the Laplacian) inside the face at the size it was analyzed.
    public var sharpness: Double?
    /// Advanced checks: sharpness of the eyes, read from a large copy of the photo.
    public var eyeSharpness: Double?
    /// Advanced checks: blinks, squints and smile from MediaPipe Face Landmarker
    /// (`FaceLandmarker`); nil when it didn't run or found no face in the box.
    public var expression: FaceExpression?

    public init(box: CGRect, quality: Double? = nil, openness: Double? = nil, skip: CullFaceSkip? = nil,
                sharpness: Double? = nil, eyeSharpness: Double? = nil, expression: FaceExpression? = nil) {
        self.box = box
        self.quality = quality
        self.openness = openness
        self.skip = skip
        self.sharpness = sharpness
        self.eyeSharpness = eyeSharpness
        self.expression = expression
    }

    public var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

/// Why a face's eyes weren't judged.
public enum CullFaceSkip: String, Sendable, Equatable {
    /// Too few pixels to tell; Advanced checks read a larger copy.
    case small
    /// Turned away: one eye much narrower than the other, or no eye outline.
    case turned
}

/// What culling concludes about one face in a group.
public enum CullEyes: Sendable, Equatable {
    case open
    case halfClosed
    case closed
    /// Not judged (too small, turned away).
    case unknown

    // Provisional thresholds, from typical eye aspect ratios (open about 0.25 to 0.35, closed
    // under 0.15). Tune them on Rosh's test photos (TestPhotos/Cull, `CullFixtureTests`).

    /// Openness below this is closed whatever else the group shows.
    public static let closedOpenness = 0.09
    /// The same person must have been seen at least this open for a comparison to count, so
    /// naturally narrow eyes or sunglasses never read as closed.
    public static let referenceOpenness = 0.16
    /// Below this share of the same person's widest openness in the group: closed.
    public static let closedShare = 0.5
    /// Below this share: half closed.
    public static let halfShare = 0.72
    /// Faces narrower than this many pixels at the standard size aren't judged.
    public static let minimumFacePixels = 40.0

    // With Advanced checks, MediaPipe's blink score (0 open ... 1 shut) decides instead of the
    // outline. Measured on Rosh's test photos (Nov 14, 2026): open eyes 0.1 to 0.3 (smiling
    // squints up to 0.3), closed 0.5 to 0.8, the half-closed shot 0.33 against 0.2 open.

    /// A blink at least this high, and `blinkRise` above the same person's lowest in the group,
    /// is closed.
    public static let blinkClosed = 0.45
    public static let blinkRise = 0.25
    /// At least this, and `blinkHalfRise` above the person's lowest: half closed.
    public static let blinkHalf = 0.3
    public static let blinkHalfRise = 0.12
    /// Closed whatever the group shows (a photo on its own, or someone blinking in every shot).
    public static let blinkAlone = 0.7
    /// A smile score at least this high counts the person as smiling.
    public static let smiling = 0.5
}

public enum CullFaceReading {
    /// Eye openness from an eye outline (points in pixels): the spread across the line between
    /// the two corners (the points farthest apart), over that line's length.
    public static func openness(of outline: [CGPoint]) -> (openness: Double, width: Double)? {
        guard outline.count >= 4 else { return nil }
        var first = outline[0], second = outline[1], widest = 0.0
        for i in outline.indices {
            for j in outline.indices where j > i {
                let d = hypot(outline[i].x - outline[j].x, outline[i].y - outline[j].y)
                if d > widest { widest = d; first = outline[i]; second = outline[j] }
            }
        }
        guard widest > 0 else { return nil }
        let ux = (second.x - first.x) / widest, uy = (second.y - first.y) / widest
        var above = 0.0, below = 0.0
        for point in outline {
            let across = (point.x - first.x) * -uy + (point.y - first.y) * ux
            above = max(above, across)
            below = min(below, across)
        }
        return ((above - below) / widest, widest)
    }

    /// Reads a face found with landmarks: eye openness (or why it can't be judged) and the
    /// face's sharpness in `plane`. `imageSize` is the size Vision analyzed, in pixels.
    public static func face(_ observation: VNFaceObservation, imageSize: CGSize, plane: GrayPlane?,
                            minimumPixels: Double = CullEyes.minimumFacePixels) -> CullFace {
        var face = CullFace(box: observation.boundingBox,
                            quality: observation.faceCaptureQuality.map(Double.init))
        if let plane {
            face.sharpness = plane.laplacianVariance(in: plane.pixelRect(fromVision: observation.boundingBox))
        }
        let pixels = observation.boundingBox.width * imageSize.width
        guard pixels >= minimumPixels else {
            face.skip = .small
            return face
        }
        let eyes = [observation.landmarks?.leftEye, observation.landmarks?.rightEye].map { region in
            region.flatMap { openness(of: $0.pointsInImage(imageSize: imageSize)) }
        }
        guard let left = eyes[0], let right = eyes[1],
              min(left.width, right.width) >= 0.5 * max(left.width, right.width) else {
            face.skip = .turned
            return face
        }
        face.openness = (left.openness + right.openness) / 2
        return face
    }

    /// The eyes' region (both outlines, with room around them) as a Vision rectangle, or nil
    /// without landmarks.
    public static func eyeRegion(_ observation: VNFaceObservation, imageSize: CGSize) -> CGRect? {
        let points = [observation.landmarks?.leftEye, observation.landmarks?.rightEye]
            .compactMap { $0?.pointsInImage(imageSize: imageSize) }.flatMap { $0 }
        guard points.count >= 4, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        var rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        rect = rect.insetBy(dx: -rect.width * 0.15, dy: -max(rect.height, rect.width * 0.2))
        return CGRect(x: rect.minX / imageSize.width, y: rect.minY / imageSize.height,
                      width: rect.width / imageSize.width, height: rect.height / imageSize.height)
    }
}

extension Culling {
    /// Matches the faces of a group's photos to people, by where they are in the frame: shots in
    /// a group are framed alike. Returns, for each photo, a person number for each face.
    public static func people(in faces: [[CullFace]], within distance: Double = 0.08) -> [[Int]] {
        var centers: [CGPoint] = []
        return faces.map { photoFaces in
            var taken: Set<Int> = []
            return photoFaces.map { face in
                let c = face.center
                let nearest = centers.indices.filter { !taken.contains($0) }
                    .min { hypot(centers[$0].x - c.x, centers[$0].y - c.y) < hypot(centers[$1].x - c.x, centers[$1].y - c.y) }
                if let nearest, hypot(centers[nearest].x - c.x, centers[nearest].y - c.y) <= max(distance, face.box.width * 0.6) {
                    taken.insert(nearest)
                    return nearest
                }
                centers.append(c)
                taken.insert(centers.count - 1)
                return centers.count - 1
            }
        }
    }

    /// Eyes open, half closed or closed for each face of each photo in a group, comparing each
    /// person with the same person in the group's other shots (so narrow eyes, glasses and
    /// squinting smiles aren't read as closed), and with a fixed floor.
    /// With Advanced checks, MediaPipe's blink scores decide where they were read, compared the
    /// same way with the person's lowest blink in the group.
    public static func eyes(in faces: [[CullFace]]) -> [[CullEyes]] {
        let people = Self.people(in: faces)
        var widest: [Int: Double] = [:]
        var lowestBlink: [Int: Double] = [:]
        for (photo, photoFaces) in faces.enumerated() {
            for (index, face) in photoFaces.enumerated() {
                let person = people[photo][index]
                if let blink = face.expression?.blink { lowestBlink[person] = min(lowestBlink[person] ?? 1, blink) }
                guard let openness = face.openness else { continue }
                widest[person] = max(widest[person] ?? 0, openness)
            }
        }
        return faces.enumerated().map { photo, photoFaces in
            photoFaces.enumerated().map { index, face in
                if let blink = face.expression?.blink {
                    let rise = blink - (lowestBlink[people[photo][index]] ?? blink)
                    if blink >= CullEyes.blinkAlone || (blink >= CullEyes.blinkClosed && rise >= CullEyes.blinkRise) {
                        return .closed
                    }
                    if blink >= CullEyes.blinkHalf, rise >= CullEyes.blinkHalfRise { return .halfClosed }
                    return .open
                }
                guard let openness = face.openness else { return .unknown }
                if openness < CullEyes.closedOpenness { return .closed }
                guard let best = widest[people[photo][index]], best >= CullEyes.referenceOpenness else { return .open }
                let share = openness / best
                if share < CullEyes.closedShare { return .closed }
                if share < CullEyes.halfShare { return .halfClosed }
                return .open
            }
        }
    }
}
