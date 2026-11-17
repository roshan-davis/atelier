import CoreGraphics
import Foundation

extension DevelopSettings {
    /// One spot of the Remove tool (AT-066), like Lightroom's: a click or a brush stroke whose
    /// area is filled. Content-Aware fills it from texture found all around it
    /// (`ContentAwareFill`); Heal and Clone from a source next to it, Heal matching the colors
    /// around the spot's edge, Clone copying the source as it is.
    ///
    /// Positions are fractions of the upright, uncropped photo (0...1, top-left origin) and the
    /// size is a fraction of its long edge, as for masks, so a spot stays put when the crop,
    /// straighten, turns or flips change, and looks the same at any render size.
    public struct Spot: Codable, Hashable, Sendable, Identifiable {
        public enum Mode: String, Codable, CaseIterable, Sendable {
            // Lightroom's order.
            case contentAware, heal, clone

            public var title: String {
                switch self {
                case .contentAware: return "Content-Aware"
                case .heal: return "Heal"
                case .clone: return "Clone"
                }
            }
        }

        public var id = UUID()
        public var mode: Mode
        /// One point for a click, the brush's path for a drag.
        public var points: [MaskPoint]
        /// Brush diameter as a fraction of the photo's long edge.
        public var size: Double
        /// 0...100; how much of the brush's radius fades out.
        public var feather: Double
        /// 0...100; how much of the fill shows.
        public var opacity: Double
        /// Where the source sits, relative to the spot, in fractions of the photo's width and height.
        public var offset: MaskPoint
        /// Content-Aware's variation: / tries another fill (another random start for the search).
        public var variation: Int
        /// Content-Aware with Generative AI on (AT-066 step 4): the fill is made by the AI
        /// recipe Remove Object in ComfyUI. Until it is in, or when ComfyUI can't be reached,
        /// the spot shows the Content-Aware fill.
        public var generative: Bool
        /// The generated fill, once ComfyUI has made it.
        public var patch: Patch?

        /// A generated fill: an image Atelier keeps in `SpotPatches`, and where it sits.
        public struct Patch: Codable, Hashable, Sendable {
            public var id: UUID
            /// The area the image covers, in fractions of the upright, uncropped photo (top-left
            /// origin), as the spot's points.
            public var region: MaskRect
            /// The average color of that area of the photo it was made from (red, green, blue in
            /// the working space), so a later White Balance or Exposure change moves the fill
            /// with the photo around it.
            public var mean: [Double]
            public var seed: UInt32

            public init(id: UUID = UUID(), region: MaskRect, mean: [Double], seed: UInt32) {
                self.id = id
                self.region = region
                self.mean = mean
                self.seed = seed
            }
        }

        public static let defaultSize = 0.03
        public static let defaultFeather = 30.0
        public static let sizeRange = 0.003...0.4

        public init(mode: Mode, points: [MaskPoint], size: Double = Spot.defaultSize,
                    feather: Double = Spot.defaultFeather, opacity: Double = 100,
                    offset: MaskPoint = MaskPoint(x: 0, y: 0), variation: Int = 0, generative: Bool = false,
                    patch: Patch? = nil) {
            self.mode = mode
            self.points = points
            self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
            self.feather = min(max(feather, 0), 100)
            self.opacity = min(max(opacity, 0), 100)
            self.offset = offset
            self.variation = variation
            self.generative = generative
            self.patch = patch
        }

        /// The source's path: the spot's moved by `offset`.
        public var sourcePoints: [MaskPoint] {
            points.map { MaskPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        }

        /// Where the spot's pin sits: the middle of its path's bounds.
        public var center: MaskPoint {
            guard let first = points.first else { return MaskPoint(x: 0.5, y: 0.5) }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return MaskPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        }

        public var sourceCenter: MaskPoint {
            MaskPoint(x: center.x + offset.x, y: center.y + offset.y)
        }

        /// The area the spot covers on a photo of `photo` pixels, brush radius and `margin`
        /// pixels included, top-left origin. Not clipped to the photo.
        public func bounds(in photo: CGSize, margin: CGFloat = 0, offset extra: MaskPoint? = nil) -> CGRect {
            let shift = extra ?? MaskPoint(x: 0, y: 0)
            let radius = CGFloat(size) * max(photo.width, photo.height) / 2 + margin
            var rect = CGRect.null
            for point in points {
                let x = CGFloat(point.x + shift.x) * photo.width, y = CGFloat(point.y + shift.y) * photo.height
                rect = rect.union(CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
            return rect
        }

        /// Whether `point` (a fraction of the photo, as `points`) is on the spot itself.
        public func contains(_ point: MaskPoint, photo: CGSize) -> Bool {
            Self.distance(from: point, to: points, photo: photo) <= CGFloat(size) * max(photo.width, photo.height) / 2
        }

        /// Whether `point` is on the spot's source.
        public func sourceContains(_ point: MaskPoint, photo: CGSize) -> Bool {
            Self.distance(from: point, to: sourcePoints, photo: photo) <= CGFloat(size) * max(photo.width, photo.height) / 2
        }

        /// The distance in pixels from `point` to the nearest point of the path.
        static func distance(from point: MaskPoint, to path: [MaskPoint], photo: CGSize) -> CGFloat {
            let p = CGPoint(x: CGFloat(point.x) * photo.width, y: CGFloat(point.y) * photo.height)
            let pixels = path.map { CGPoint(x: CGFloat($0.x) * photo.width, y: CGFloat($0.y) * photo.height) }
            guard let first = pixels.first else { return .infinity }
            var best = hypot(p.x - first.x, p.y - first.y)
            for (a, b) in zip(pixels, pixels.dropFirst()) {
                let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let length = ab.x * ab.x + ab.y * ab.y
                let t = length > 0 ? min(1, max(0, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / length)) : 0
                best = min(best, hypot(p.x - (a.x + ab.x * t), p.y - (a.y + ab.y * t)))
            }
            return best
        }

        private enum CodingKeys: String, CodingKey {
            case id, mode, points, size, feather, opacity, offset, variation, generative, patch
        }

        /// Missing keys take their defaults, so spots keep loading as fields are added.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .heal
            points = try c.decodeIfPresent([MaskPoint].self, forKey: .points) ?? []
            size = try c.decodeIfPresent(Double.self, forKey: .size) ?? Self.defaultSize
            feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? Self.defaultFeather
            opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 100
            offset = try c.decodeIfPresent(MaskPoint.self, forKey: .offset) ?? MaskPoint(x: 0, y: 0)
            variation = try c.decodeIfPresent(Int.self, forKey: .variation) ?? 0
            generative = try c.decodeIfPresent(Bool.self, forKey: .generative) ?? false
            patch = try? c.decodeIfPresent(Patch.self, forKey: .patch)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(mode, forKey: .mode)
            try c.encode(points, forKey: .points)
            try c.encode(size, forKey: .size)
            try c.encode(feather, forKey: .feather)
            if opacity != 100 { try c.encode(opacity, forKey: .opacity) }
            try c.encode(offset, forKey: .offset)
            if variation != 0 { try c.encode(variation, forKey: .variation) }
            if generative { try c.encode(generative, forKey: .generative) }
            try c.encodeIfPresent(patch, forKey: .patch)
        }
    }
}

/// Picks where a Heal or Clone spot takes its fill from, as Lightroom does when you click:
/// a nearby area of the photo that looks like the spot's surroundings.
public enum SpotSource {
    /// Offsets to try, in fractions of the photo's width and height: eight directions at two
    /// distances, each just far enough that the source doesn't overlap the spot, keeping only
    /// sources that lie wholly on the photo. Nearest first.
    public static func candidates(for spot: DevelopSettings.Spot, photo: CGSize) -> [DevelopSettings.MaskPoint] {
        guard photo.width > 0, photo.height > 0, !spot.points.isEmpty else { return [] }
        let bounds = spot.bounds(in: photo)
        let diameter = CGFloat(spot.size) * max(photo.width, photo.height)
        var result: [(distance: CGFloat, offset: DevelopSettings.MaskPoint)] = []
        for step in 0..<8 {
            let angle = CGFloat(step) * .pi / 4 - .pi / 2  // straight up first, then clockwise
            let ux = cos(angle), uy = sin(angle)
            // How far the bounds must move along (ux, uy) to clear themselves.
            let clearX = abs(ux) > 0.001 ? bounds.width / abs(ux) : .infinity
            let clearY = abs(uy) > 0.001 ? bounds.height / abs(uy) : .infinity
            let clear = min(clearX, clearY)
            for distance in [clear + diameter * 0.25, clear * 1.5 + diameter * 0.5] {
                let dx = ux * distance, dy = uy * distance
                let moved = bounds.offsetBy(dx: dx, dy: dy)
                guard moved.minX >= 0, moved.minY >= 0, moved.maxX <= photo.width, moved.maxY <= photo.height else { continue }
                result.append((distance, DevelopSettings.MaskPoint(x: Double(dx / photo.width), y: Double(dy / photo.height))))
            }
        }
        return result.sorted { $0.distance < $1.distance }.map(\.offset)
    }

    /// The candidates, best first. `brightness` reads the photo's brightness (0...1) at a point
    /// (fractions of the upright, uncropped photo), or nil where it can't be seen (outside the
    /// crop). A candidate scores by how alike the ring just around the spot and the same ring
    /// around the source look, both in level and in texture, plus a little for distance, so the
    /// nearest of equally good sources wins. Without `brightness` they come nearest first.
    public static func ranked(for spot: DevelopSettings.Spot, photo: CGSize,
                              brightness: ((DevelopSettings.MaskPoint) -> Double?)?) -> [DevelopSettings.MaskPoint] {
        let candidates = candidates(for: spot, photo: photo)
        guard let brightness, !candidates.isEmpty else { return candidates }
        let ring = ringPoints(for: spot, photo: photo)
        let own = ring.map { brightness($0) }
        let longEdge = Double(max(photo.width, photo.height))
        let scored = candidates.enumerated().map { index, offset -> (Double, Int, DevelopSettings.MaskPoint) in
            var difference = 0.0, counted = 0, missing = 0
            var previous: (Double, Double)?
            var texture = 0.0
            for (point, mine) in zip(ring, own) {
                let there = brightness(DevelopSettings.MaskPoint(x: point.x + offset.x, y: point.y + offset.y))
                guard let mine, let there else { missing += 1; previous = nil; continue }
                difference += abs(mine - there)
                if let previous { texture += abs((mine - previous.0) - (there - previous.1)) }
                previous = (mine, there)
                counted += 1
            }
            let seen = Double(max(counted, 1))
            let pixels = hypot(offset.x * Double(photo.width), offset.y * Double(photo.height))
            let score = difference / seen + texture / seen * 0.5 + Double(missing) / Double(max(ring.count, 1))
                + pixels / longEdge * 0.05
            return (score, index, offset)
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    /// The offset after `current` in the ranked list, for Lightroom's / key (new source),
    /// wrapping around. The first one when `current` isn't among them.
    public static func next(after current: DevelopSettings.MaskPoint, in ranked: [DevelopSettings.MaskPoint],
                            photo: CGSize) -> DevelopSettings.MaskPoint? {
        guard !ranked.isEmpty else { return nil }
        let near = ranked.firstIndex {
            hypot(($0.x - current.x) * Double(photo.width), ($0.y - current.y) * Double(photo.height)) < 2
        }
        guard let near else { return ranked[0] }
        return ranked[(near + 1) % ranked.count]
    }

    /// Points on a ring just outside the spot: around a round spot, or along both sides and the
    /// ends of a stroke.
    static func ringPoints(for spot: DevelopSettings.Spot, photo: CGSize) -> [DevelopSettings.MaskPoint] {
        let longEdge = max(photo.width, photo.height)
        let radius = CGFloat(spot.size) * longEdge / 2 * 1.35
        // At most 8 places along a stroke, each ringed with 16 samples.
        let path = spot.points
        let stride = max(1, path.count / 8)
        var places: [DevelopSettings.MaskPoint] = []
        for index in Swift.stride(from: 0, to: path.count, by: stride) { places.append(path[index]) }
        if let last = path.last, places.last != last { places.append(last) }
        var result: [DevelopSettings.MaskPoint] = []
        for place in places {
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                let x = CGFloat(place.x) * photo.width + cos(angle) * radius
                let y = CGFloat(place.y) * photo.height + sin(angle) * radius
                let point = DevelopSettings.MaskPoint(x: Double(x / photo.width), y: Double(y / photo.height))
                // Points on another part of the stroke aren't the surroundings.
                if DevelopSettings.Spot.distance(from: point, to: path, photo: photo) < radius * 0.95 { continue }
                result.append(point)
            }
        }
        return result
    }
}

/// A small grayscale copy of a photo for `SpotSource.ranked`, read at fractions of its size.
public struct BrightnessMap: Sendable {
    public let width: Int
    public let height: Int
    public let values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    /// The image drawn into `longEdge` pixels or fewer, its brightness gamma-encoded as on screen.
    public init?(_ image: CGImage, longEdge: Int = 384) {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, values: bytes.map { Float($0) / 255 })
    }

    /// Brightness at `x`, `y` (0...1 from the top left), or nil off the image.
    public func value(x: Double, y: Double) -> Double? {
        guard x >= 0, y >= 0, x <= 1, y <= 1, width > 0, height > 0 else { return nil }
        let column = min(width - 1, Int(x * Double(width)))
        let row = min(height - 1, Int(y * Double(height)))
        return Double(values[row * width + column])
    }
}
