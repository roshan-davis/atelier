import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

extension DevelopSettings {
    /// Select People: parts of the people Vision finds, like Lightroom's People masks. Each person
    /// with a visible face is found; face skin, body skin and each facial feature are separate
    /// parts, ticked in any combination.
    public struct PeopleSelection: Codable, Hashable, Sendable {
        public enum Part: String, Codable, CaseIterable, Sendable {
            case faceSkin, bodySkin, eyebrows, eyeSclera, iris, lips, teeth, hair, clothes, entirePerson

            public var title: String {
                switch self {
                case .faceSkin: return "Face Skin"
                case .bodySkin: return "Body Skin"
                case .eyebrows: return "Eyebrows"
                case .eyeSclera: return "Eye Sclera"
                case .iris: return "Iris and Pupil"
                case .lips: return "Lips"
                case .teeth: return "Teeth"
                case .hair: return "Hair"
                case .clothes: return "Clothes"
                case .entirePerson: return "Entire Person"
                }
            }

            /// What the part covers, for its tooltip.
            public var help: String {
                switch self {
                case .faceSkin: return "The face's skin, leaving out eyes, brows and lips"
                case .bodySkin: return "Neck, arms, hands and other skin on the same person"
                case .eyebrows: return "Both eyebrows"
                case .eyeSclera: return "The whites of the eyes"
                case .iris: return "The colored part of the eyes and the pupils"
                case .lips: return "Upper and lower lip"
                case .teeth: return "Teeth showing between the lips"
                case .hair: return "Hair on the head"
                case .clothes: return "Clothes, scarves and hats"
                case .entirePerson: return "The whole person"
                }
            }
        }

        /// The parts a new Select People part starts with.
        public static let defaultParts: [Part] = [.faceSkin, .bodySkin]

        /// Which person, counted from the left (0 is the leftmost face); nil is everyone.
        public var person: Int?
        /// The parts selected, in `Part.allCases` order. May be empty while choosing (selects nothing).
        public var parts: [Part]
        /// 0...100; softens the edge.
        public var feather = 10.0
        /// 0...100; snaps the edge to the photo's edges (0 is off).
        public var refine = 0.0
        /// -100...100; shrinks (below 0) or grows (above 0) the selection.
        public var grow = 0.0
        /// Redraws the edge with the Fine Edges model (BiRefNet) when it is downloaded.
        public var fineEdges = false

        public init(person: Int? = nil, parts: [Part] = PeopleSelection.defaultParts, feather: Double = 10,
                    refine: Double = 0, grow: Double = 0, fineEdges: Bool = false) {
            self.person = person
            self.parts = Part.allCases.filter(parts.contains)
            self.feather = feather
            self.refine = refine
            self.grow = grow
            self.fineEdges = fineEdges
        }

        public func includes(_ part: Part) -> Bool { parts.contains(part) }

        /// The same selection with `part` ticked or unticked.
        public func setting(_ part: Part, _ on: Bool) -> PeopleSelection {
            var changed = self
            changed.parts = Part.allCases.filter { $0 == part ? on : parts.contains($0) }
            return changed
        }

        private enum CodingKeys: String, CodingKey { case person, parts, feather, refine, grow, fineEdges }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            person = try c.decodeIfPresent(Int.self, forKey: .person)
            // Parts saved before the facial features existed meant face and body skin.
            let stored = try c.decodeIfPresent([String].self, forKey: .parts) ?? Self.defaultParts.map(\.rawValue)
            parts = Part.allCases.filter { stored.contains($0.rawValue) }
            feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 10
            refine = try c.decodeIfPresent(Double.self, forKey: .refine) ?? 0
            grow = try c.decodeIfPresent(Double.self, forKey: .grow) ?? 0
            fineEdges = try c.decodeIfPresent(Bool.self, forKey: .fineEdges) ?? false
        }
    }
}

/// A face as Vision outlines it, in the analysed image's pixels (top-left origin): the outline of
/// the face (jaw line closed over the forehead), the features inside it that aren't skin (eyes,
/// brows; cut out of Face Skin a little larger than drawn), and the outlines Select People's
/// feature parts are made from.
public struct FaceShape: Sendable, Equatable {
    /// One eye: its outline (lid to lid) and its pupil when Vision finds it.
    public struct Eye: Sendable, Equatable {
        public var outline: [CGPoint]
        public var pupil: CGPoint?

        public init(outline: [CGPoint], pupil: CGPoint? = nil) {
            self.outline = outline
            self.pupil = pupil
        }
    }

    public var box: CGRect
    public var outline: [CGPoint]
    public var features: [[CGPoint]]
    public var brows: [[CGPoint]]
    public var eyes: [Eye]
    public var outerLips: [CGPoint]
    public var innerLips: [CGPoint]

    public init(box: CGRect, outline: [CGPoint], features: [[CGPoint]] = [], brows: [[CGPoint]] = [],
                eyes: [Eye] = [], outerLips: [CGPoint] = [], innerLips: [CGPoint] = []) {
        self.box = box
        self.outline = outline
        self.features = features
        self.brows = brows
        self.eyes = eyes
        self.outerLips = outerLips
        self.innerLips = innerLips
    }

    /// An ellipse inside the face box, for a face Vision gave no landmarks for.
    public static func ellipse(in box: CGRect) -> FaceShape {
        let center = CGPoint(x: box.midX, y: box.midY + box.height * 0.05)
        let outline = (0..<24).map { i -> CGPoint in
            let t = Double(i) / 24 * 2 * .pi
            return CGPoint(x: center.x + box.width * 0.42 * CGFloat(cos(t)), y: center.y + box.height * 0.5 * CGFloat(sin(t)))
        }
        return FaceShape(box: box, outline: outline)
    }

    /// The face's outline from Vision's jaw contour (ear to ear, under the chin) closed with a
    /// half-ellipse over the forehead that reaches an eighth of the face's height above the brows
    /// (higher reaches into hats and hairlines, which are often skin-colored).
    public static func outline(jaw: [CGPoint], brows: [CGPoint], box: CGRect) -> [CGPoint] {
        guard let first = jaw.first, let last = jaw.last, jaw.count >= 3 else { return ellipse(in: box).outline }
        let mid = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        let radius = hypot(last.x - first.x, last.y - first.y) / 2
        let browTop = brows.map(\.y).min() ?? (box.minY + box.height * 0.3)
        let up = max(0, mid.y - browTop) + box.height * 0.12
        // Over the top from `last` back to `first`.
        let goesRight = last.x >= first.x
        var arc: [CGPoint] = []
        for i in 1..<16 {
            let t = Double(i) / 16
            let angle = goesRight ? -t * .pi : .pi + t * .pi
            arc.append(CGPoint(x: mid.x + radius * CGFloat(cos(angle)), y: mid.y + up * CGFloat(sin(angle))))
        }
        return jaw + arc
    }
}

/// Face and body skin of the people in an image, found once and combined per selection.
public struct PeopleSkin: Sendable {
    public struct Person: Sendable {
        /// The face, 0 to 1 from the top left of the analysed image.
        public var face: CGRect
        var faceSkin: [Float]
        var bodySkin: [Float]
        /// Eyebrows, sclera, iris, lips and teeth, each kept only around where it is.
        var features: [DevelopSettings.PeopleSelection.Part: Patch] = [:]
    }

    /// Part of a mask: the values inside a rectangle of the analysed image, 0 elsewhere.
    struct Patch: Sendable {
        var x: Int, y: Int, width: Int, height: Int
        var values: [Float]

        func add(to out: inout [Float], imageWidth: Int) {
            for row in 0..<height {
                for column in 0..<width {
                    let v = values[row * width + column]
                    let i = (y + row) * imageWidth + x + column
                    if i < out.count, v > out[i] { out[i] = v }
                }
            }
        }
    }

    public let width: Int
    public let height: Int
    /// Ordered left to right by face.
    public let people: [Person]

    /// Long edge the analysis runs at.
    public static let size = 1024

    /// The selection's mask (1 is skin), `width` × `height`, rows from the top.
    public func values(_ selection: DevelopSettings.PeopleSelection) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for (index, person) in people.enumerated() where selection.person == nil || selection.person == index {
            for part in selection.parts {
                switch part {
                case .faceSkin, .bodySkin:
                    let values = part == .faceSkin ? person.faceSkin : person.bodySkin
                    for i in 0..<min(out.count, values.count) where values[i] > out[i] { out[i] = values[i] }
                default:
                    person.features[part]?.add(to: &out, imageWidth: width)
                }
            }
        }
        return out
    }

    /// The selection as an 8-bit gray image (white is skin), rows from the top.
    public func mask(_ selection: DevelopSettings.PeopleSelection) -> CGImage? {
        PeopleSkin.grayImage(values(selection), width: width, height: height)
    }

    // MARK: Finding people

    /// Finds the people and their skin with Vision, on a copy at most `size` pixels on the long
    /// edge. Nil when no face is found.
    public static func find(in image: CGImage) -> PeopleSkin? {
        let factor = min(1, Double(size) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let pixels = LookSample.pixels(of: image, width: width, height: height),
              let small = rgbaImage(pixels.pixels, width: width, height: height) else { return nil }
        let faceRequest = VNDetectFaceLandmarksRequest()
        let personRequest = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: small)
        guard (try? handler.perform([faceRequest])) != nil else { return nil }
        let imageSize = CGSize(width: width, height: height)
        var faces = (faceRequest.results ?? []).map { faceShape($0, imageSize: imageSize) }
        var mattes: [[Float]] = []
        if (try? handler.perform([personRequest])) != nil, let observation = personRequest.results?.first {
            for instance in observation.allInstances {
                if let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler),
                   let values = matteValues(buffer, width: width, height: height) {
                    mattes.append(values)
                }
            }
        }
        // A person Vision outlines but whose face it missed at this size (sunglasses, turned
        // away, small in the frame): look again for a face on their head, enlarged; failing that,
        // they are still a person, with a head box guessed from their outline.
        for missing in facelessPeople(mattes: mattes, faces: faces, width: width, height: height) {
            faces.append(face(in: missing.head, of: small) ?? FaceShape(box: missing.head, outline: []))
        }
        guard !faces.isEmpty else { return nil }
        if mattes.isEmpty {
            // Older systems or an odd image: one matte for everyone.
            let segmentation = VNGeneratePersonSegmentationRequest()
            segmentation.qualityLevel = .accurate
            if (try? handler.perform([segmentation])) != nil, let buffer = segmentation.results?.first?.pixelBuffer,
               let values = matteValues(buffer, width: width, height: height) {
                mattes.append(values)
            }
        }
        // The built-in parts model when it loads; Vision and skin color alone otherwise.
        let segment: ((CGRect) -> [[Float]]?)? = PeopleParts.isAvailable
            ? { PeopleParts.segment(pixels: pixels.pixels, width: width, height: height, region: $0) }
            : nil
        return build(pixels: pixels.pixels, width: width, height: height, faces: faces, mattes: mattes,
                     seeds: limbSeeds(handler, imageSize: imageSize), segment: segment)
    }

    /// The people (instance mattes) with no found face's middle inside them, at least 0.5% of the
    /// image: their outline's extent and the head box guessed from it (the top of the outline, as
    /// wide as a third of the person and a bit taller than wide, centered on the outline there).
    static func facelessPeople(mattes: [[Float]], faces: [FaceShape], width: Int, height: Int)
        -> [(extent: CGRect, head: CGRect)] {
        var result: [(extent: CGRect, head: CGRect)] = []
        for matte in mattes where matte.count == width * height {
            let covered = faces.contains { face in
                let x = min(width - 1, max(0, Int(face.box.midX))), y = min(height - 1, max(0, Int(face.box.midY)))
                return matte[y * width + x] > 0.3
            }
            guard !covered else { continue }
            var minX = width, minY = height, maxX = -1, maxY = -1, area = 0
            for i in 0..<matte.count where matte[i] > 0.3 {
                let x = i % width, y = i / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                area += 1
            }
            guard maxX >= 0, Double(area) >= 0.005 * Double(width * height) else { continue }
            let extent = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            let side = max(4, min(extent.width * 0.35, extent.height * 0.25))
            // Middle of the outline's top band.
            var sum = 0, n = 0
            for y in minY..<min(maxY + 1, minY + Int(side)) {
                for x in minX...maxX where matte[y * width + x] > 0.3 { sum += x; n += 1 }
            }
            let middle = n > 0 ? CGFloat(sum) / CGFloat(n) : extent.midX
            result.append((extent, CGRect(x: middle - side / 2, y: extent.minY, width: side, height: side * 1.25)))
        }
        return result
    }

    /// The largest face Vision finds in `region` (pixels, top left) of `image`, enlarged so the
    /// region is about 640 pixels across, in `image`'s pixels.
    static func face(in region: CGRect, of image: CGImage) -> FaceShape? {
        let area = region.insetBy(dx: -region.width * 0.6, dy: -region.height * 0.4).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard area.width >= 8, area.height >= 8, let piece = image.cropping(to: area) else { return nil }
        let scale = max(1, min(8, 640 / max(area.width, area.height)))
        let w = Int(area.width * scale), h = Int(area.height * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: DevelopRenderer.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let enlarged = context.makeImage() else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: enlarged).perform([request])) != nil,
              let best = (request.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let found = faceShape(best, imageSize: CGSize(width: w, height: h))
        func back(_ p: CGPoint) -> CGPoint { CGPoint(x: area.minX + p.x / scale, y: area.minY + p.y / scale) }
        func backAll(_ points: [CGPoint]) -> [CGPoint] { points.map { back($0) } }
        let box = CGRect(x: area.minX + found.box.minX / scale, y: area.minY + found.box.minY / scale,
                         width: found.box.width / scale, height: found.box.height / scale)
        return FaceShape(box: box, outline: backAll(found.outline), features: found.features.map { backAll($0) },
                         brows: found.brows.map { backAll($0) },
                         eyes: found.eyes.map { FaceShape.Eye(outline: backAll($0.outline), pupil: $0.pupil.map { back($0) }) },
                         outerLips: backAll(found.outerLips), innerLips: backAll(found.innerLips))
    }

    /// Where bare arms and hands usually are, from Vision's body and hand poses (no model of our
    /// own): each wrist, a point a quarter of the way up the forearm, and every hand joint. A seed
    /// on a sleeve finds no smooth skin next to it and grows nothing.
    static func limbSeeds(_ handler: VNImageRequestHandler, imageSize: CGSize) -> [CGPoint] {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 8
        guard (try? handler.perform([bodyRequest, handRequest])) != nil else { return [] }
        func point(_ p: VNRecognizedPoint?) -> CGPoint? {
            guard let p, p.confidence > 0.3 else { return nil }
            return CGPoint(x: p.location.x * imageSize.width, y: (1 - p.location.y) * imageSize.height)
        }
        var seeds: [CGPoint] = []
        for body in bodyRequest.results ?? [] {
            guard let joints = try? body.recognizedPoints(.all) else { continue }
            for (elbow, wrist) in [(VNHumanBodyPoseObservation.JointName.leftElbow, VNHumanBodyPoseObservation.JointName.leftWrist),
                                   (.rightElbow, .rightWrist)] {
                guard let w = point(joints[wrist]) else { continue }
                seeds.append(w)
                if let e = point(joints[elbow]) {
                    seeds.append(CGPoint(x: w.x + (e.x - w.x) * 0.25, y: w.y + (e.y - w.y) * 0.25))
                }
            }
        }
        for hand in handRequest.results ?? [] {
            guard let joints = try? hand.recognizedPoints(.all) else { continue }
            seeds += joints.values.compactMap { point($0) }
        }
        return seeds
    }

    static func faceShape(_ face: VNFaceObservation, imageSize: CGSize) -> FaceShape {
        let w = imageSize.width, h = imageSize.height
        let b = face.boundingBox
        let box = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: h - $0.y) }
        }
        guard let landmarks = face.landmarks else { return .ellipse(in: box) }
        let jaw = points(landmarks.faceContour)
        let leftBrow = points(landmarks.leftEyebrow), rightBrow = points(landmarks.rightEyebrow)
        let leftEye = points(landmarks.leftEye), rightEye = points(landmarks.rightEye)
        let eyes = [FaceShape.Eye(outline: leftEye, pupil: points(landmarks.leftPupil).first),
                    FaceShape.Eye(outline: rightEye, pupil: points(landmarks.rightPupil).first)]
            .filter { $0.outline.count >= 3 }
        let outerLips = points(landmarks.outerLips), innerLips = points(landmarks.innerLips)
        let features = [leftEye, rightEye, leftBrow, rightBrow].filter { $0.count >= 3 }
        let brows = [leftBrow, rightBrow].filter { $0.count >= 2 }
        let outline = jaw.count >= 3 ? FaceShape.outline(jaw: jaw, brows: leftBrow + rightBrow, box: box)
                                     : FaceShape.ellipse(in: box).outline
        return FaceShape(box: box, outline: outline, features: features, brows: brows, eyes: eyes,
                         outerLips: outerLips, innerLips: innerLips)
    }

    // MARK: Skin from faces and mattes (no Vision; tested directly)

    /// With `segment` (the built-in MediaPipe parts model, `PeopleParts`, run on a box around each
    /// person and returning per-class chances at full size), Face Skin, Body Skin, Hair, Clothes
    /// and Entire Person come from the model, kept to that person's matte, with eyes, brows and
    /// lips cut out of Face Skin. Without it, as follows.
    /// Each face's skin color is learned from the face itself (inside its outline, leaving out the
    /// eyes, brows and lips), then looked for on the face (Face Skin). Body Skin is grown, not
    /// just color-matched: it starts from the neck just under the jaw and from `seeds` (wrists,
    /// forearms and hands from Vision's poses, in pixels from the top left) and spreads over that
    /// person's matte only to neighbors of the face's skin color that are smooth (skin has little
    /// texture, knit and fabric have more) and close in color (no edge between them). So a warm
    /// scarf, hat or coat touching the neck stops the growth at its edge, and skin-colored specks
    /// that no seed reaches are left out.
    public static func build(pixels: [UInt8], width: Int, height: Int, faces: [FaceShape],
                             mattes: [[Float]], seeds: [CGPoint] = [],
                             segment: ((CGRect) -> [[Float]]?)? = nil) -> PeopleSkin? {
        let count = width * height
        guard count > 0, pixels.count >= count * 4 else { return nil }
        var lab = [SIMD3<Float>](repeating: .zero, count: count)
        let linear = LookSample.linearTable
        for i in 0..<count {
            let v = LookSample.oklab(linear[Int(pixels[i * 4])], linear[Int(pixels[i * 4 + 1])], linear[Int(pixels[i * 4 + 2])])
            lab[i] = SIMD3(Float(v.0), Float(v.1), Float(v.2))
        }
        let lightness = lab.map(\.x)
        let usableMattes = mattes.filter { $0.count == count }
        let ordered = faces.sorted(by: { $0.box.midX < $1.box.midX })
        var people: [Person] = []
        for (faceIndex, face) in ordered.enumerated() {
            var holes = [Float](repeating: 0, count: count)
            for feature in face.features {
                let grown = raster(scaled(feature, by: 1.35), width: width, height: height)
                for i in 0..<count where grown[i] > holes[i] { holes[i] = grown[i] }
            }
            // Lips are cut out closer to their edge, so Face Skin and Lips together leave no gap.
            if face.outerLips.count >= 3 {
                let lips = raster(scaled(face.outerLips, by: 1.1), width: width, height: height)
                for i in 0..<count where lips[i] > holes[i] { holes[i] = lips[i] }
            }
            // The person whose matte covers the face's middle.
            let center = min(height - 1, max(0, Int(face.box.midY))) * width + min(width - 1, max(0, Int(face.box.midX)))
            let matte = usableMattes.max { $0[center] < $1[center] }.flatMap { $0[center] > 0.3 ? $0 : nil }

            var faceSkin: [Float], bodySkin: [Float]
            var modelParts: [(DevelopSettings.PeopleSelection.Part, [Float])] = []
            let region = personRegion(face: face, matte: matte, width: width, height: height)
            if !region.isEmpty, let classes = segment?(region), classes.count == PeopleParts.Class.allCases.count,
               classes.allSatisfy({ $0.count == count }) {
                // The built-in model tells skin from clothes and hair; kept to this person.
                var keep = [Float](repeating: 0, count: count)
                if let matte {
                    keep = matte
                } else {
                    for y in Int(region.minY)..<Int(region.maxY) {
                        for x in Int(region.minX)..<Int(region.maxX) { keep[y * width + x] = 1 }
                    }
                }
                func part(_ c: PeopleParts.Class) -> [Float] { (0..<count).map { classes[c.rawValue][$0] * keep[$0] } }
                faceSkin = (0..<count).map { classes[PeopleParts.Class.faceSkin.rawValue][$0] * keep[$0] * (1 - holes[$0]) }
                bodySkin = part(.bodySkin)
                let person = matte ?? (0..<count).map { (1 - classes[PeopleParts.Class.background.rawValue][$0]) * keep[$0] }
                modelParts = [(.hair, part(.hair)), (.clothes, part(.clothes)), (.entirePerson, person)]
            } else {
                (faceSkin, bodySkin) = colorSkin(face: face, faceIndex: faceIndex, faces: ordered, holes: holes,
                                                 matte: matte, seeds: seeds, lab: lab, width: width, height: height)
            }
            let guide = lightness
            let radius = max(2, max(width, height) / 300)
            faceSkin = guidedFilter(faceSkin, guide: guide, width: width, height: height, radius: radius)
            bodySkin = guidedFilter(bodySkin, guide: guide, width: width, height: height, radius: radius)
            var features: [DevelopSettings.PeopleSelection.Part: Patch] = [:]
            for (part, map) in modelParts {
                if let patch = patch(map, guide: guide, width: width, height: height, radius: radius) {
                    features[part] = patch
                }
            }
            // Features are small: a finer edge than skin's.
            let featureRadius = max(1, radius / 2)
            for (part, map) in featureMaps(face, lab: lab, width: width, height: height) {
                if let patch = patch(map, guide: guide, width: width, height: height, radius: featureRadius) {
                    features[part] = patch
                }
            }
            people.append(Person(face: CGRect(x: face.box.minX / CGFloat(width), y: face.box.minY / CGFloat(height),
                                              width: face.box.width / CGFloat(width), height: face.box.height / CGFloat(height)),
                                 faceSkin: faceSkin, bodySkin: bodySkin, features: features))
        }
        guard !people.isEmpty else { return nil }
        return PeopleSkin(width: width, height: height, people: people)
    }

    /// Where to look for one person's parts, in pixels: their matte's extent, or without a matte
    /// a box around the face reaching down over the body; a little margin all round.
    static func personRegion(face: FaceShape, matte: [Float]?, width: Int, height: Int) -> CGRect {
        var box = CGRect(x: face.box.minX - face.box.width * 1.5, y: face.box.minY - face.box.height * 0.6,
                         width: face.box.width * 4, height: face.box.height * 5.6)
        if let matte {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for i in 0..<min(matte.count, width * height) where matte[i] > 0.3 {
                let x = i % width, y = i / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            if maxX >= 0 {
                box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1).union(face.box)
            }
        }
        box = box.insetBy(dx: -box.width * 0.06, dy: -box.height * 0.06).integral
        return box.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Face and body skin without the model (when it can't load): each face's skin color is
    /// learned from the face itself, then looked for on the face; body skin is grown from the neck
    /// and the pose seeds over smooth pixels of that color.
    static func colorSkin(face: FaceShape, faceIndex: Int, faces ordered: [FaceShape], holes: [Float], matte: [Float]?,
                          seeds: [CGPoint], lab: [SIMD3<Float>], width: Int, height: Int) -> ([Float], [Float]) {
        let count = width * height
        let outline = raster(face.outline, width: width, height: height)
        var samples: [SIMD3<Float>] = []
        for i in 0..<count where outline[i] > 0.5 && holes[i] < 0.5 && looksLikeSkin(lab[i]) {
            samples.append(lab[i])
        }
        // Sunglasses, a scarf or a small face can leave too few clean skin pixels to learn the
        // face's color from. Then learn it from the whole outline (holes included), and failing
        // that use the loose skin test, so the person is still found and their features
        // (lips, teeth, brows) still work.
        var model = SkinModel(samples: samples)
        if model == nil {
            var loose: [SIMD3<Float>] = []
            for i in 0..<count where outline[i] > 0.5 && looksLikeSkin(lab[i]) { loose.append(lab[i]) }
            model = SkinModel(samples: loose)
        }
        let likelihood: [Float] = model.map { m in lab.map { m.likelihood($0) } }
            ?? lab.map { looksLikeSkin($0) ? 0.6 : 0 }

        var faceSkin = [Float](repeating: 0, count: count)
        for i in 0..<count { faceSkin[i] = outline[i] * (1 - holes[i]) * likelihood[i] }

        var bodySkin = [Float](repeating: 0, count: count)
        if let matte {
            func nearestFace(_ p: CGPoint) -> Int? {
                ordered.indices.min { hypot(ordered[$0].box.midX - p.x, ordered[$0].box.midY - p.y)
                    < hypot(ordered[$1].box.midX - p.x, ordered[$1].box.midY - p.y) }
            }
            let texture = localDeviation(lab.map(\.x), width: width, height: height)
            // Hair: the band above the forehead, as wide as the face.
            let hairBottom = face.outline.map(\.y).min() ?? face.box.minY
            let hairTop = hairBottom - face.box.height * 0.6
            var allowed = [Bool](repeating: false, count: count)
            for i in 0..<count {
                let x = CGFloat(i % width), y = CGFloat(i / width)
                let hair = y < hairBottom && y > hairTop
                    && x > face.box.minX - face.box.width * 0.2 && x < face.box.maxX + face.box.width * 0.2
                allowed[i] = !hair && matte[i] > 0.4 && outline[i] < 0.5 && likelihood[i] > 0.15
                    && texture[i] < maxSkinTexture
            }
            let chin = face.outline.map(\.y).max() ?? face.box.maxY
            var starts = [CGPoint(x: face.box.midX, y: chin + face.box.height * 0.12)]
            starts += seeds.filter { nearestFace($0) == faceIndex }
            let grown = grow(from: starts, allowed: allowed, likelihood: likelihood, lab: lab,
                             width: width, height: height)
            for i in 0..<count where grown[i] { bodySkin[i] = 1 }
        }
        return (faceSkin, bodySkin)
    }

    /// Eyebrows, sclera, iris and pupil, lips and teeth of one face from Vision's outlines, before
    /// edge smoothing. Brows are drawn as a band along Vision's brow line (filled too, when the
    /// points close round the brow). The iris is a disc at the pupil, 42% of the eye's width
    /// across, clipped by the lids; the sclera is the rest of the eye where it is light (not
    /// lashes or shadow). Lips are the outer lip outline less the mouth opening; teeth are the
    /// light, nearly colorless pixels inside the opening.
    static func featureMaps(_ face: FaceShape, lab: [SIMD3<Float>], width: Int, height: Int)
        -> [(DevelopSettings.PeopleSelection.Part, [Float])] {
        let count = width * height
        func ramp(_ v: Float, _ a: Float, _ b: Float) -> Float {
            let t = min(1, max(0, (v - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        var result: [(DevelopSettings.PeopleSelection.Part, [Float])] = []

        var brows = [Float](repeating: 0, count: count)
        let browThickness = max(1.5, face.box.height * 0.05)
        for brow in face.brows {
            let line = stroke(brow, thickness: browThickness, width: width, height: height)
            let filled = brow.count >= 3 ? raster(brow, width: width, height: height) : line
            for i in 0..<count { brows[i] = max(brows[i], line[i], filled[i]) }
        }
        result.append((.eyebrows, brows))

        var iris = [Float](repeating: 0, count: count), sclera = iris
        for eye in face.eyes {
            let inside = raster(eye.outline, width: width, height: height)
            let xs = eye.outline.map(\.x)
            let eyeWidth = (xs.max() ?? 0) - (xs.min() ?? 0)
            let center = eye.pupil ?? CGPoint(x: xs.reduce(0, +) / CGFloat(max(1, xs.count)),
                                              y: eye.outline.map(\.y).reduce(0, +) / CGFloat(max(1, eye.outline.count)))
            let round = disc(center: center, radius: max(1, eyeWidth * 0.21), width: width, height: height)
            for i in 0..<count where inside[i] > 0 {
                iris[i] = max(iris[i], inside[i] * round[i])
                sclera[i] = max(sclera[i], inside[i] * (1 - round[i]) * ramp(lab[i].x, 0.45, 0.62))
            }
        }
        result.append((.eyeSclera, sclera))
        result.append((.iris, iris))

        var lips = [Float](repeating: 0, count: count), teeth = lips
        if face.outerLips.count >= 3 {
            let outer = raster(face.outerLips, width: width, height: height)
            let opening = face.innerLips.count >= 3 ? raster(face.innerLips, width: width, height: height)
                                                    : [Float](repeating: 0, count: count)
            for i in 0..<count {
                lips[i] = outer[i] * (1 - opening[i])
                guard opening[i] > 0 else { continue }
                let chroma = (lab[i].y * lab[i].y + lab[i].z * lab[i].z).squareRoot()
                teeth[i] = opening[i] * ramp(lab[i].x, 0.5, 0.65) * (1 - ramp(chroma, 0.04, 0.08))
            }
        }
        result.append((.lips, lips))
        result.append((.teeth, teeth))
        return result
    }

    /// `map` smoothed along the photo's edges and kept only around where it isn't 0; nil when it
    /// is 0 everywhere.
    static func patch(_ map: [Float], guide: [Float], width: Int, height: Int, radius: Int) -> Patch? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for i in 0..<min(map.count, width * height) where map[i] > 0.001 {
            let x = i % width, y = i / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        let margin = radius * 2 + 2
        let x0 = max(0, minX - margin), y0 = max(0, minY - margin)
        let x1 = min(width - 1, maxX + margin), y1 = min(height - 1, maxY + margin)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var values = [Float](repeating: 0, count: w * h), light = values
        for row in 0..<h {
            for column in 0..<w {
                let i = (y0 + row) * width + x0 + column
                values[row * w + column] = map[i]
                light[row * w + column] = guide[i]
            }
        }
        return Patch(x: x0, y: y0, width: w, height: h,
                     values: guidedFilter(values, guide: light, width: w, height: h, radius: radius))
    }

    /// 1 within `thickness / 2` of the polyline, 0 elsewhere.
    static func stroke(_ line: [CGPoint], thickness: CGFloat, width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        guard let first = line.first else { return out }
        let half = thickness / 2
        let segments = line.count > 1 ? Array(zip(line, line.dropFirst())) : [(first, first)]
        let minX = max(0, Int(floor((line.map(\.x).min() ?? 0) - half)))
        let maxX = min(width - 1, Int(ceil((line.map(\.x).max() ?? 0) + half)))
        let minY = max(0, Int(floor((line.map(\.y).min() ?? 0) - half)))
        let maxY = min(height - 1, Int(ceil((line.map(\.y).max() ?? 0) + half)))
        guard minX <= maxX, minY <= maxY else { return out }
        for y in minY...maxY {
            for x in minX...maxX {
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                for (a, b) in segments {
                    let dx = b.x - a.x, dy = b.y - a.y
                    let length = dx * dx + dy * dy
                    let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
                    if hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)) <= half {
                        out[y * width + x] = 1
                        break
                    }
                }
            }
        }
        return out
    }

    /// 1 inside the circle (pixel centers), 0 outside.
    static func disc(center: CGPoint, radius: CGFloat, width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        let minX = max(0, Int(floor(center.x - radius))), maxX = min(width - 1, Int(ceil(center.x + radius)))
        let minY = max(0, Int(floor(center.y - radius))), maxY = min(height - 1, Int(ceil(center.y + radius)))
        guard minX <= maxX, minY <= maxY else { return out }
        for y in minY...maxY {
            for x in minX...maxX where hypot(CGFloat(x) + 0.5 - center.x, CGFloat(y) + 0.5 - center.y) <= radius {
                out[y * width + x] = 1
            }
        }
        return out
    }

    /// A loose test that a color could be skin at all, whatever the skin tone: warm hues, some
    /// color but not much, neither black nor white.
    static func looksLikeSkin(_ c: SIMD3<Float>) -> Bool {
        let chroma = (c.y * c.y + c.z * c.z).squareRoot()
        guard c.x > 0.2, c.x < 0.96, chroma > 0.012, chroma < 0.25 else { return false }
        let hue = atan2(c.z, c.y) * 180 / .pi
        return hue > 0 && hue < 115
    }

    /// The skin color of one face in Oklab: mean and covariance, refitted after leaving out the
    /// 15% of samples farthest from the first fit (shadows under the nose, stubble, highlights).
    struct SkinModel {
        var mean: SIMD3<Double>
        /// Rows of the inverse covariance.
        var inverse: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

        init?(samples: [SIMD3<Float>]) {
            guard samples.count >= 30 else { return nil }
            var kept = samples.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            var fit = Self.fit(kept)
            for _ in 0..<2 {
                guard let current = fit else { return nil }
                let distances = kept.map { current.distance($0) }
                let cut = distances.sorted()[Int(Double(distances.count - 1) * 0.85)]
                let trimmed = zip(kept, distances).filter { $0.1 <= cut }.map(\.0)
                guard trimmed.count >= 20 else { break }
                kept = trimmed
                fit = Self.fit(kept)
            }
            guard let result = fit else { return nil }
            self = result
        }

        private init(mean: SIMD3<Double>, inverse: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)) {
            self.mean = mean
            self.inverse = inverse
        }

        static func fit(_ samples: [SIMD3<Double>]) -> SkinModel? {
            let n = Double(samples.count)
            guard n >= 3 else { return nil }
            let mean = samples.reduce(SIMD3<Double>.zero, +) / n
            var cov = [[Double]](repeating: [0, 0, 0], count: 3)
            for s in samples {
                let d = s - mean
                for r in 0..<3 { for c in 0..<3 { cov[r][c] += d[r] * d[c] / n } }
            }
            // Skin in shadow or light keeps its color but not its lightness: allow much more
            // lightness spread than the face shows, and a floor so a flat face isn't too strict.
            cov[0][0] = cov[0][0] * 2 + 0.0025
            cov[1][1] += 0.00012
            cov[2][2] += 0.00012
            guard let inverse = invert3(cov) else { return nil }
            return SkinModel(mean: mean, inverse: (SIMD3(inverse[0][0], inverse[0][1], inverse[0][2]),
                                                   SIMD3(inverse[1][0], inverse[1][1], inverse[1][2]),
                                                   SIMD3(inverse[2][0], inverse[2][1], inverse[2][2])))
        }

        /// Squared Mahalanobis distance.
        func distance(_ x: SIMD3<Double>) -> Double {
            let d = x - mean
            let m = SIMD3((inverse.0 * d).sum(), (inverse.1 * d).sum(), (inverse.2 * d).sum())
            return (d * m).sum()
        }

        /// 1 for colors well inside the face's spread, fading to 0 past it (chi-square 3
        /// degrees of freedom: 90% at 6.25, 99% at 11.3).
        func likelihood(_ c: SIMD3<Float>) -> Float {
            let d = distance(SIMD3(Double(c.x), Double(c.y), Double(c.z)))
            let t = min(1, max(0, (d - 6.25) / (11.3 - 6.25)))
            return Float(1 - t * t * (3 - 2 * t))
        }
    }

    static func invert3(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], k = m[2][2]
        let det = a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-18 else { return nil }
        return [[(e * k - f * h) / det, (c * h - b * k) / det, (b * f - c * e) / det],
                [(f * g - d * k) / det, (a * k - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    }

    // MARK: Pixel helpers

    /// A polygon grown or shrunk about its middle.
    static func scaled(_ polygon: [CGPoint], by factor: CGFloat) -> [CGPoint] {
        guard !polygon.isEmpty else { return polygon }
        let cx = polygon.map(\.x).reduce(0, +) / CGFloat(polygon.count)
        let cy = polygon.map(\.y).reduce(0, +) / CGFloat(polygon.count)
        return polygon.map { CGPoint(x: cx + ($0.x - cx) * factor, y: cy + ($0.y - cy) * factor) }
    }

    /// 1 inside the polygon (pixel centers, even-odd rule), 0 outside.
    static func raster(_ polygon: [CGPoint], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        guard polygon.count >= 3 else { return out }
        let minY = max(0, Int(floor(polygon.map(\.y).min()!))), maxY = min(height - 1, Int(ceil(polygon.map(\.y).max()!)))
        guard minY <= maxY else { return out }
        for y in minY...maxY {
            let py = CGFloat(y) + 0.5
            var crossings: [CGFloat] = []
            for (a, b) in zip(polygon, polygon.dropFirst() + [polygon[0]]) where (a.y <= py) != (b.y <= py) {
                crossings.append(a.x + (py - a.y) / (b.y - a.y) * (b.x - a.x))
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let x0 = max(0, Int(ceil(crossings[i] - 0.5))), x1 = min(width - 1, Int(floor(crossings[i + 1] - 0.5)))
                if x0 <= x1 { for x in x0...x1 { out[y * width + x] = 1 } }
                i += 2
            }
        }
        return out
    }

    /// Skin is smooth at this size; knit, fabric and hair vary more from pixel to pixel.
    static let maxSkinTexture: Float = 0.025
    /// The largest color step (Oklab) growth crosses between neighbors; a seam or edge is larger.
    static let maxSkinStep: Float = 0.03

    /// Grows a region from each start (moved to the nearest allowed pixel that is clearly skin,
    /// within 3% of the image) through allowed neighbors whose color differs by less than
    /// `maxSkinStep`.
    static func grow(from starts: [CGPoint], allowed: [Bool], likelihood: [Float], lab: [SIMD3<Float>],
                     width: Int, height: Int) -> [Bool] {
        let count = width * height
        var grown = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        let reach = max(2, max(width, height) * 3 / 100)
        for start in starts {
            let sx = Int(start.x), sy = Int(start.y)
            var best: (distance: Int, index: Int)?
            for dy in -reach...reach {
                for dx in -reach...reach {
                    let x = sx + dx, y = sy + dy
                    guard x >= 0, y >= 0, x < width, y < height else { continue }
                    let i = y * width + x
                    guard allowed[i], likelihood[i] > 0.5 else { continue }
                    let d = dx * dx + dy * dy
                    if d < best?.distance ?? .max { best = (d, i) }
                }
            }
            if let best, !grown[best.index] {
                grown[best.index] = true
                stack.append(best.index)
            }
        }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let j = ny * width + nx
                guard !grown[j], allowed[j] else { continue }
                let step = lab[j] - lab[i]
                guard (step * step).sum() < maxSkinStep * maxSkinStep else { continue }
                grown[j] = true
                stack.append(j)
            }
        }
        return grown
    }

    /// The standard deviation of `values` over each pixel's 3 × 3 neighborhood.
    static func localDeviation(_ values: [Float], width: Int, height: Int) -> [Float] {
        let mean = boxMean(values, width: width, height: height, radius: 1)
        let meanSquare = boxMean(values.map { $0 * $0 }, width: width, height: height, radius: 1)
        return zip(meanSquare, mean).map { max(0, $0 - $1 * $1).squareRoot() }
    }

    /// He, Sun and Tang's guided filter (2010): smooths the mask while keeping its edges on the
    /// photo's edges, so it follows the jaw and arms without a halo.
    static func guidedFilter(_ p: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float = 1e-3) -> [Float] {
        let count = width * height
        let meanI = boxMean(guide, width: width, height: height, radius: radius)
        let meanP = boxMean(p, width: width, height: height, radius: radius)
        let meanIP = boxMean(zip(guide, p).map { $0 * $1 }, width: width, height: height, radius: radius)
        let meanII = boxMean(guide.map { $0 * $0 }, width: width, height: height, radius: radius)
        var a = [Float](repeating: 0, count: count), b = a
        for i in 0..<count {
            let variance = meanII[i] - meanI[i] * meanI[i]
            a[i] = (meanIP[i] - meanI[i] * meanP[i]) / (variance + epsilon)
            b[i] = meanP[i] - a[i] * meanI[i]
        }
        let meanA = boxMean(a, width: width, height: height, radius: radius)
        let meanB = boxMean(b, width: width, height: height, radius: radius)
        return (0..<count).map { min(1, max(0, meanA[$0] * guide[$0] + meanB[$0])) }
    }

    /// Mean over a (2 radius + 1) square, clipped at the image's edges, from a summed-area table.
    static func boxMean(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let stride = width + 1
        var table = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += Double(values[y * width + x])
                table[(y + 1) * stride + x + 1] = table[y * stride + x + 1] + row
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
                let sum = table[y1 * stride + x1] - table[y0 * stride + x1] - table[y1 * stride + x0] + table[y0 * stride + x0]
                out[y * width + x] = Float(sum / Double((y1 - y0) * (x1 - x0)))
            }
        }
        return out
    }

    /// A Vision matte (any size, 8-bit or float) as values at `width` × `height`, rows from the top.
    static func matteValues(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [Float]? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard image.extent.width > 0, image.extent.height > 0,
              let gray = context.createCGImage(image, from: image.extent, format: .L8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.linearGray)),
              let values = LookSample.focusValues(gray, width: width, height: height) else { return nil }
        return values.map { Float($0) }
    }

    static let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    static func grayImage(_ values: [Float], width: Int, height: Int) -> CGImage? {
        let bytes = values.map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func rgbaImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: DevelopRenderer.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
