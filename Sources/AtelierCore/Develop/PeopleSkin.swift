import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

extension DevelopSettings {
    /// Select People: skin on the people Vision finds, like Lightroom's People masks. Each person
    /// with a visible face is found; their face skin and body skin are separate parts.
    public struct PeopleSelection: Codable, Hashable, Sendable {
        public enum Part: String, Codable, CaseIterable, Sendable {
            case faceSkin, bodySkin

            public var title: String {
                switch self {
                case .faceSkin: return "Face Skin"
                case .bodySkin: return "Body Skin"
                }
            }
        }

        /// Which person, counted from the left (0 is the leftmost face); nil is everyone.
        public var person: Int?
        /// The parts selected, in `Part.allCases` order.
        public var parts: [Part]
        /// 0...100; softens the edge.
        public var feather = 10.0

        public init(person: Int? = nil, parts: [Part] = Part.allCases, feather: Double = 10) {
            self.person = person
            self.parts = Part.allCases.filter(parts.contains)
            self.feather = feather
        }

        public func includes(_ part: Part) -> Bool { parts.contains(part) }

        private enum CodingKeys: String, CodingKey { case person, parts, feather }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            person = try c.decodeIfPresent(Int.self, forKey: .person)
            let stored = try c.decodeIfPresent([String].self, forKey: .parts) ?? Part.allCases.map(\.rawValue)
            parts = Part.allCases.filter { stored.contains($0.rawValue) }
            feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 10
        }
    }
}

/// A face as Vision outlines it, in the analysed image's pixels (top-left origin): the outline of
/// the face (jaw line closed over the forehead) and the features inside it that aren't skin
/// (eyes, brows, lips).
public struct FaceShape: Sendable, Equatable {
    public var box: CGRect
    public var outline: [CGPoint]
    public var features: [[CGPoint]]

    public init(box: CGRect, outline: [CGPoint], features: [[CGPoint]] = []) {
        self.box = box
        self.outline = outline
        self.features = features
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
                let values = part == .faceSkin ? person.faceSkin : person.bodySkin
                for i in 0..<min(out.count, values.count) where values[i] > out[i] { out[i] = values[i] }
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
        let faces = (faceRequest.results ?? []).map { faceShape($0, imageSize: imageSize) }
        guard !faces.isEmpty else { return nil }
        var mattes: [[Float]] = []
        if (try? handler.perform([personRequest])) != nil, let observation = personRequest.results?.first {
            for instance in observation.allInstances {
                if let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler),
                   let values = matteValues(buffer, width: width, height: height) {
                    mattes.append(values)
                }
            }
        }
        if mattes.isEmpty {
            // Older systems or an odd image: one matte for everyone.
            let segmentation = VNGeneratePersonSegmentationRequest()
            segmentation.qualityLevel = .accurate
            if (try? handler.perform([segmentation])) != nil, let buffer = segmentation.results?.first?.pixelBuffer,
               let values = matteValues(buffer, width: width, height: height) {
                mattes.append(values)
            }
        }
        return build(pixels: pixels.pixels, width: width, height: height, faces: faces, mattes: mattes)
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
        let features = [points(landmarks.leftEye), points(landmarks.rightEye), leftBrow, rightBrow,
                        points(landmarks.outerLips)].filter { $0.count >= 3 }
        guard jaw.count >= 3 else { return FaceShape(box: box, outline: FaceShape.ellipse(in: box).outline, features: features) }
        return FaceShape(box: box, outline: FaceShape.outline(jaw: jaw, brows: leftBrow + rightBrow, box: box),
                         features: features)
    }

    // MARK: Skin from faces and mattes (no Vision; tested directly)

    /// Each face's skin color is learned from the face itself (inside its outline, leaving out the
    /// eyes, brows and lips), then looked for on the face (Face Skin) and over that person's matte
    /// (Body Skin: neck, arms, hands). Body skin starts where the face's outline ends, so the two
    /// together leave no gap under the jaw. It keeps only pieces joined to the face or big enough
    /// to be a limb, so specks of skin-colored background or clothes are left out.
    public static func build(pixels: [UInt8], width: Int, height: Int, faces: [FaceShape],
                             mattes: [[Float]]) -> PeopleSkin? {
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
        var people: [Person] = []
        for face in faces.sorted(by: { $0.box.midX < $1.box.midX }) {
            let outline = raster(face.outline, width: width, height: height)
            var holes = [Float](repeating: 0, count: count)
            for feature in face.features {
                let grown = raster(scaled(feature, by: 1.35), width: width, height: height)
                for i in 0..<count where grown[i] > holes[i] { holes[i] = grown[i] }
            }
            var samples: [SIMD3<Float>] = []
            for i in 0..<count where outline[i] > 0.5 && holes[i] < 0.5 && looksLikeSkin(lab[i]) {
                samples.append(lab[i])
            }
            guard let model = SkinModel(samples: samples) else { continue }
            let likelihood = lab.map { model.likelihood($0) }

            var faceSkin = [Float](repeating: 0, count: count)
            for i in 0..<count { faceSkin[i] = outline[i] * (1 - holes[i]) * likelihood[i] }

            // The person whose matte covers the face's middle.
            let center = (min(height - 1, max(0, Int(face.box.midY))), min(width - 1, max(0, Int(face.box.midX))))
            let matte = usableMattes.max { $0[center.0 * width + center.1] < $1[center.0 * width + center.1] }
            var bodySkin = [Float](repeating: 0, count: count)
            if let matte, matte[center.0 * width + center.1] > 0.3 {
                let near = raster(scaled(face.outline, by: 1.6), width: width, height: height)
                // Hair: the band above the forehead, as wide as the face.
                let hairBottom = face.outline.map(\.y).min() ?? face.box.minY
                let hairTop = hairBottom - face.box.height * 0.6
                for i in 0..<count {
                    let x = CGFloat(i % width), y = CGFloat(i / width)
                    if y < hairBottom, y > hairTop, x > face.box.minX - face.box.width * 0.2, x < face.box.maxX + face.box.width * 0.2 { continue }
                    bodySkin[i] = matte[i] * likelihood[i] * (1 - outline[i])
                }
                keepJoined(&bodySkin, width: width, height: height, near: near, minimumShare: 0.002)
            }
            let guide = lightness
            let radius = max(2, max(width, height) / 300)
            faceSkin = guidedFilter(faceSkin, guide: guide, width: width, height: height, radius: radius)
            bodySkin = guidedFilter(bodySkin, guide: guide, width: width, height: height, radius: radius)
            people.append(Person(face: CGRect(x: face.box.minX / CGFloat(width), y: face.box.minY / CGFloat(height),
                                              width: face.box.width / CGFloat(width), height: face.box.height / CGFloat(height)),
                                 faceSkin: faceSkin, bodySkin: bodySkin))
        }
        guard !people.isEmpty else { return nil }
        return PeopleSkin(width: width, height: height, people: people)
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

    /// Leaves out pieces of the mask (above half) that neither touch `near` nor hold
    /// `minimumShare` of the image.
    static func keepJoined(_ mask: inout [Float], width: Int, height: Int, near: [Float], minimumShare: Double) {
        let count = width * height
        var label = [Int32](repeating: -1, count: count)
        var stack: [Int] = []
        let minimum = Int(Double(count) * minimumShare)
        for start in 0..<count where mask[start] > 0.5 && label[start] < 0 {
            var piece: [Int] = []
            var touches = false
            label[start] = 0
            stack.append(start)
            while let i = stack.popLast() {
                piece.append(i)
                if near[i] > 0.5 { touches = true }
                let x = i % width, y = i / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let j = ny * width + nx
                    if label[j] < 0, mask[j] > 0.5 {
                        label[j] = 0
                        stack.append(j)
                    }
                }
            }
            if !touches && piece.count < minimum {
                for i in piece { mask[i] = 0 }
            }
        }
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
