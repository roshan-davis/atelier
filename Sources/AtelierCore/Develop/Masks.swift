import CoreGraphics
import Foundation

extension DevelopSettings {
    /// A local adjustment, like a Lightroom mask: where it applies (its components, combined in
    /// order) and what it does there (its own sliders).
    ///
    /// Positions are fractions of the upright, uncropped photo (0...1, top-left origin) and
    /// lengths are fractions of its long edge, so masks stay on the same spot when the crop,
    /// straighten, turns or flips change, and look the same at any render size.
    public struct Mask: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var components: [MaskComponent]
        /// Hidden masks keep their settings but have no effect (the eye in the Masks panel).
        public var isHidden = false
        public var inverted = false
        /// Scales every slider of the mask, 0...200 percent.
        public var amount = 100.0
        private var values: [String: Double] = [:]

        public init(name: String, components: [MaskComponent] = []) {
            self.name = name
            self.components = components
        }

        public subscript(parameter: LocalParameter) -> Double {
            get { values[parameter.rawValue] ?? 0 }
            set {
                let value = min(max(newValue, parameter.range.lowerBound), parameter.range.upperBound)
                values[parameter.rawValue] = value == 0 ? nil : value
            }
        }

        public var hasAdjustments: Bool { !values.isEmpty }

        public mutating func resetAdjustments() {
            values = [:]
            amount = 100
        }

        /// A slider's value with Amount applied, as the renderer uses it.
        public func effective(_ parameter: LocalParameter) -> Double {
            let value = self[parameter] * amount / 100
            return min(max(value, parameter.range.lowerBound * 2), parameter.range.upperBound * 2)
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, components, isHidden, inverted, amount, values
        }

        /// Missing keys take their defaults, so masks keep loading as fields are added.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mask"
            components = try c.decodeIfPresent([MaskComponent].self, forKey: .components) ?? []
            isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
            inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
            amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
            let stored = try c.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
            for (key, value) in stored {
                if let parameter = LocalParameter(rawValue: key) { self[parameter] = value }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(components, forKey: .components)
            if isHidden { try c.encode(isHidden, forKey: .isHidden) }
            if inverted { try c.encode(inverted, forKey: .inverted) }
            if amount != 100 { try c.encode(amount, forKey: .amount) }
            if !values.isEmpty { try c.encode(values, forKey: .values) }
        }
    }

    /// The sliders a mask has, in Lightroom's order.
    public enum LocalParameter: String, CaseIterable, Sendable {
        case temperature, tint
        case exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze
        case hue, saturation
        case sharpness, noise, moire, defringe

        public var label: String {
            switch self {
            case .temperature: return "Temp"
            case .moire: return "Moiré"
            default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }

        public var range: ClosedRange<Double> {
            switch self {
            case .exposure: return -4...4
            // Hue turns colors by degrees (AT-068), as far as Lightroom's (a full turn across the track).
            case .hue: return -180...180
            // Remove only, like Noise: there is nothing to add.
            case .noise, .moire, .defringe: return 0...100
            default: return -100...100
            }
        }

        /// Sliders are shown in these groups, separated by a little space.
        public var group: Int {
            switch self {
            case .temperature, .tint: return 0
            case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: return 1
            case .texture, .clarity, .dehaze: return 2
            case .hue, .saturation: return 3
            case .sharpness, .noise, .moire, .defringe: return 4
            }
        }
    }

    /// A point on the upright, uncropped photo: fractions of its width and height from the top left.
    public struct MaskPoint: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        public init(_ point: CGPoint) {
            self.init(x: Double(point.x), y: Double(point.y))
        }

        public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

    /// One part of a mask.
    public struct MaskComponent: Codable, Hashable, Sendable, Identifiable {
        /// How the part combines with the parts before it.
        public enum Mode: String, Codable, CaseIterable, Sendable {
            case add, subtract, intersect

            public var title: String { rawValue.capitalized }

            /// The badge in the Masks panel.
            public var symbol: String {
                switch self {
                case .add: return "plus.circle.fill"
                case .subtract: return "minus.circle.fill"
                case .intersect: return "circle.circle"
                }
            }
        }

        public enum Kind: String, Codable, CaseIterable, Sendable {
            case brush, linear, radial, luminance, color, subject, background, object, people

            public var title: String {
                switch self {
                case .brush: return "Brush"
                case .linear: return "Linear Gradient"
                case .radial: return "Radial Gradient"
                case .luminance: return "Luminance Range"
                case .color: return "Color Range"
                case .subject: return "Select Subject"
                case .background: return "Select Background"
                case .object: return "Select Object"
                case .people: return "Select People"
                }
            }

            public var symbol: String {
                switch self {
                case .brush: return "paintbrush.pointed"
                case .linear: return "square.bottomhalf.filled"
                case .radial: return "circle.dashed.inset.filled"
                case .luminance: return "sun.max"
                case .color: return "eyedropper"
                case .subject: return "person.crop.rectangle"
                case .background: return "person.and.background.dotted"
                case .object: return "viewfinder"
                case .people: return "person.2"
                }
            }

            /// Drawn (or, for Color Range, picked) on the photo; the others are made straight from the menu.
            public var isDrawn: Bool {
                self == .brush || self == .linear || self == .radial || self == .object || self == .color
            }
        }

        public enum Shape: Hashable, Sendable {
            case brush([MaskStroke])
            case linear(LinearGradient)
            case radial(RadialGradient)
            case luminance(LuminanceRange)
            /// Color Range (AT-068): the colors picked on the photo.
            case color(ColorRange)
            /// Select Subject (no box), Select Object (inside a box) or Select Background (the
            /// subject turned inside out), found by Vision.
            case subject(Selection)
            /// Select People: face and body skin of the people Vision finds.
            case people(PeopleSelection)

            public var kind: Kind {
                switch self {
                case .brush: return .brush
                case .linear: return .linear
                case .radial: return .radial
                case .luminance: return .luminance
                case .color: return .color
                case .subject(let selection):
                    if selection.background { return .background }
                    return selection.box == nil ? .subject : .object
                case .people: return .people
                }
            }
        }

        public var id = UUID()
        public var mode: Mode
        public var inverted = false
        public var shape: Shape

        public init(_ shape: Shape, mode: Mode = .add) {
            self.shape = shape
            self.mode = mode
        }

        public var kind: Kind { shape.kind }

        /// Where the part's pin sits on the photo, if it has one.
        public var pin: MaskPoint? {
            switch shape {
            case .linear(let gradient):
                return MaskPoint(x: (gradient.start.x + gradient.end.x) / 2, y: (gradient.start.y + gradient.end.y) / 2)
            case .radial(let gradient): return gradient.center
            case .brush(let strokes): return strokes.first?.points.first
            case .subject(let selection):
                return selection.box.map { MaskPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) }
            case .color(let range): return range.samples.first?.center
            case .luminance, .people: return nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case id, mode, inverted, kind, strokes, linear, radial, luminance, color, selection, people
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .add
            inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
            switch try c.decode(Kind.self, forKey: .kind) {
            case .brush: shape = .brush(try c.decodeIfPresent([MaskStroke].self, forKey: .strokes) ?? [])
            case .linear: shape = .linear(try c.decode(LinearGradient.self, forKey: .linear))
            case .radial: shape = .radial(try c.decode(RadialGradient.self, forKey: .radial))
            case .luminance: shape = .luminance(try c.decodeIfPresent(LuminanceRange.self, forKey: .luminance) ?? LuminanceRange())
            case .color: shape = .color(try c.decodeIfPresent(ColorRange.self, forKey: .color) ?? ColorRange())
            case .subject: shape = .subject(try c.decodeIfPresent(Selection.self, forKey: .selection) ?? Selection(feather: 0))
            case .background:
                var selection = try c.decodeIfPresent(Selection.self, forKey: .selection) ?? Selection()
                selection.background = true
                shape = .subject(selection)
            case .object: shape = .subject(try c.decode(Selection.self, forKey: .selection))
            case .people: shape = .people(try c.decodeIfPresent(PeopleSelection.self, forKey: .people) ?? PeopleSelection())
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(mode, forKey: .mode)
            if inverted { try c.encode(inverted, forKey: .inverted) }
            try c.encode(kind, forKey: .kind)
            switch shape {
            case .brush(let strokes): try c.encode(strokes, forKey: .strokes)
            case .linear(let gradient): try c.encode(gradient, forKey: .linear)
            case .radial(let gradient): try c.encode(gradient, forKey: .radial)
            case .luminance(let range): try c.encode(range, forKey: .luminance)
            case .color(let range): try c.encode(range, forKey: .color)
            case .subject(let selection): try c.encode(selection, forKey: .selection)
            case .people(let selection): try c.encode(selection, forKey: .people)
            }
        }
    }

    /// A rectangle on the upright, uncropped photo, in fractions of its width and height.
    public struct MaskRect: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// The rectangle with these two corners, kept on the photo.
        public init(_ a: MaskPoint, _ b: MaskPoint) {
            let x0 = min(max(min(a.x, b.x), 0), 1), x1 = min(max(max(a.x, b.x), 0), 1)
            let y0 = min(max(min(a.y, b.y), 0), 1), y1 = min(max(max(a.y, b.y), 0), 1)
            self.init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        public var corners: [MaskPoint] {
            [MaskPoint(x: x, y: y), MaskPoint(x: x + width, y: y), MaskPoint(x: x + width, y: y + height),
             MaskPoint(x: x, y: y + height)]
        }
    }

    /// What Vision selects: the main subject of the whole photo, or the object inside `box`.
    public struct Selection: Codable, Hashable, Sendable {
        public var box: MaskRect?
        /// 0...100; softens Vision's hard edge.
        public var feather = 20.0
        /// 0...100; snaps the edge to the photo's edges (0 is off).
        public var refine = 0.0
        /// -100...100; shrinks (below 0) or grows (above 0) the selection.
        public var grow = 0.0
        /// Redraws the edge with the Fine Edges model (BiRefNet) when it is downloaded.
        public var fineEdges = false
        /// Select Background (AT-068): everything except the subject Vision finds. Grow grows the
        /// background (shrinks the subject).
        public var background = false

        public init(box: MaskRect? = nil, feather: Double = 20, refine: Double = 0, grow: Double = 0,
                    fineEdges: Bool = false, background: Bool = false) {
            self.box = box
            self.feather = feather
            self.refine = refine
            self.grow = grow
            self.fineEdges = fineEdges
            self.background = background
        }

        private enum CodingKeys: String, CodingKey { case box, feather, refine, grow, fineEdges, background }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            box = try c.decodeIfPresent(MaskRect.self, forKey: .box)
            // Masks made before the slider existed keep their hard edge.
            feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0
            refine = try c.decodeIfPresent(Double.self, forKey: .refine) ?? 0
            grow = try c.decodeIfPresent(Double.self, forKey: .grow) ?? 0
            fineEdges = try c.decodeIfPresent(Bool.self, forKey: .fineEdges) ?? false
            background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? false
        }
    }

    /// Full effect at `start`, fading to none at `end`.
    public struct LinearGradient: Codable, Hashable, Sendable {
        public var start: MaskPoint
        public var end: MaskPoint

        public init(start: MaskPoint, end: MaskPoint) {
            self.start = start
            self.end = end
        }
    }

    /// An ellipse with a soft edge: full effect inside the feathered part, none outside.
    public struct RadialGradient: Codable, Hashable, Sendable {
        public var center: MaskPoint
        /// Half-axes as fractions of the photo's long edge.
        public var radiusX: Double
        public var radiusY: Double
        /// Clockwise turn of the ellipse in degrees.
        public var angle = 0.0
        /// 0...100; how much of the radius fades out.
        public var feather = 50.0

        public init(center: MaskPoint, radiusX: Double, radiusY: Double, angle: Double = 0, feather: Double = 50) {
            self.center = center
            self.radiusX = radiusX
            self.radiusY = radiusY
            self.angle = angle
            self.feather = feather
        }
    }

    /// One brush stroke.
    public struct MaskStroke: Codable, Hashable, Sendable {
        public var points: [MaskPoint]
        /// Brush diameter as a fraction of the photo's long edge.
        public var size: Double
        /// 0...100; how much of the brush's radius fades out.
        public var feather: Double
        /// 0...100; how much each pass of the brush adds.
        public var flow: Double
        /// Erasing strokes take the mask away.
        public var erases: Bool

        public init(points: [MaskPoint], size: Double, feather: Double = 50, flow: Double = 100, erases: Bool = false) {
            self.points = points
            self.size = size
            self.feather = feather
            self.flow = flow
            self.erases = erases
        }
    }

    /// Brightness from `low` to `high` (0...100, perceptual), with a soft edge of `smoothness`.
    public struct LuminanceRange: Codable, Hashable, Sendable {
        public var low = 0.0
        public var high = 100.0
        public var smoothness = 50.0

        public init(low: Double = 0, high: Double = 100, smoothness: Double = 50) {
            self.low = low
            self.high = high
            self.smoothness = smoothness
        }

        /// How much of the mask is kept at brightness `x` (0...1).
        public func weight(at x: Double) -> Double {
            let lo = min(low, high) / 100, hi = max(low, high) / 100
            let soft = max(0.002, smoothness / 100 * 0.3)
            let distance = x < lo ? lo - x : x > hi ? x - hi : 0
            let t = max(0, 1 - distance / soft)
            return t * t * (3 - 2 * t)
        }
    }

    /// Color Range (AT-068, Lightroom's Color Range mask): the colors picked on the photo, up to
    /// five, and how far from them the mask reaches (Refine). The mask is found on the corrected
    /// photo (before tone and color), like Select Subject, so global sliders don't move it.
    public struct ColorRange: Codable, Hashable, Sendable {
        /// Lightroom allows five picks per Color Range part.
        public static let maxSamples = 5

        public var samples: [ColorSample] = []
        /// 0...100: lower keeps only colors close to the picks, higher reaches further.
        public var refine = 50.0

        public init(samples: [ColorSample] = [], refine: Double = 50) {
            self.samples = samples
            self.refine = refine
        }

        /// How far (in Oklab) from a pick the mask is still full, and where it has faded out.
        public func reach(of sample: ColorSample) -> (full: Double, zero: Double) {
            let amount: Double = min(max(refine, 0), 100) / 100
            let zero: Double = 0.012 + amount * 0.14 + sample.spread
            return (zero * 0.45, zero)
        }

        /// How much of the mask is kept for a color (Oklab L, a, b).
        public func weight(of lab: SIMD3<Double>) -> Double {
            var best = 0.0
            for sample in samples.prefix(Self.maxSamples) {
                let (full, zero) = reach(of: sample)
                let distance = ColorSample.distance(lab, sample.lab)
                let ramp: Double = (zero - distance) / max(zero - full, 1e-6)
                let t: Double = max(0, min(1, ramp))
                best = max(best, t * t * (3 - 2 * t))
            }
            return best
        }
    }

    /// One pick of a Color Range: where it was taken (a box on the upright, uncropped photo; a
    /// click is a small box) and the color found there, in Oklab.
    public struct ColorSample: Codable, Hashable, Sendable {
        public var box: MaskRect
        public var l: Double
        public var a: Double
        public var b: Double
        /// How much the picked area's colors vary (Oklab distance, RMS); a dragged box over a
        /// sky gradient widens the range by this much.
        public var spread: Double

        public init(box: MaskRect, lab: SIMD3<Double>, spread: Double = 0) {
            self.box = box
            l = lab.x
            a = lab.y
            b = lab.z
            self.spread = spread
        }

        public var lab: SIMD3<Double> { SIMD3(l, a, b) }
        public var center: MaskPoint { MaskPoint(x: box.x + box.width / 2, y: box.y + box.height / 2) }

        /// Color distance for Color Range: hue and saturation count fully, lightness half as much
        /// (a red in shade is still the red), as Lightroom's picks behave.
        public static func distance(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> Double {
            let d = x - y
            let chroma: Double = d.y * d.y + d.z * d.z
            let lightness: Double = 0.25 * d.x * d.x
            return (chroma + lightness).squareRoot()
        }
    }

    /// The next free "Mask n" name.
    public func nextMaskName() -> String {
        let used = masks.compactMap { mask -> Int? in
            guard mask.name.hasPrefix("Mask ") else { return nil }
            return Int(mask.name.dropFirst(5))
        }
        return "Mask \((used.max() ?? 0) + 1)"
    }
}

extension DevelopSettings.Crop {
    /// Where a point of the upright, uncropped photo (pixels, top-left origin) lands on the
    /// cropped photo, for a photo of `sourceSize` pixels. Follows `DevelopRenderer.applyGeometry`.
    public func outputPoint(fromSource point: CGPoint, sourceSize: CGSize) -> CGPoint {
        var p = point
        var size = sourceSize
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            // A clockwise quarter turn.
            p = CGPoint(x: size.height - p.y, y: p.x)
            size = CGSize(width: size.height, height: size.width)
        }
        if flipHorizontal { p.x = size.width - p.x }
        if flipVertical { p.y = size.height - p.y }
        if angle != 0 {
            let radians = angle * .pi / 180
            let c = CGFloat(cos(radians)), s = CGFloat(sin(radians))
            let dx = p.x - size.width / 2, dy = p.y - size.height / 2
            p = CGPoint(x: size.width / 2 + dx * c - dy * s, y: size.height / 2 + dx * s + dy * c)
        }
        return CGPoint(x: p.x - CGFloat(x) * size.width, y: p.y - CGFloat(y) * size.height)
    }

    /// The inverse of `outputPoint(fromSource:sourceSize:)`.
    public func sourcePoint(fromOutput point: CGPoint, sourceSize: CGSize) -> CGPoint {
        var size = orientedSize(sourceSize)
        var p = CGPoint(x: point.x + CGFloat(x) * size.width, y: point.y + CGFloat(y) * size.height)
        if angle != 0 {
            let radians = angle * .pi / 180
            let c = CGFloat(cos(radians)), s = CGFloat(sin(radians))
            let dx = p.x - size.width / 2, dy = p.y - size.height / 2
            p = CGPoint(x: size.width / 2 + dx * c + dy * s, y: size.height / 2 - dx * s + dy * c)
        }
        if flipVertical { p.y = size.height - p.y }
        if flipHorizontal { p.x = size.width - p.x }
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            p = CGPoint(x: p.y, y: size.width - p.x)
            size = CGSize(width: size.height, height: size.width)
        }
        return p
    }
}

/// Maps between a mask's coordinates (fractions of the upright, uncropped photo) and a view
/// showing the cropped photo fitted in `rect`.
public struct MaskSpace: Sendable {
    /// The decoded photo's size, upright and uncropped, in pixels.
    public let sourceSize: CGSize
    public let crop: DevelopSettings.Crop
    /// Where the cropped photo is drawn.
    public let rect: CGRect
    /// The cropped photo's size in pixels, as rendered.
    public let outputSize: CGSize

    public init(sourceSize: CGSize, crop: DevelopSettings.Crop, rect: CGRect, outputSize: CGSize) {
        self.sourceSize = sourceSize
        self.crop = crop
        self.rect = rect
        self.outputSize = outputSize
    }

    public var longEdge: CGFloat { max(sourceSize.width, sourceSize.height) }

    /// View points per photo pixel.
    public var viewScale: CGFloat { outputSize.width > 0 ? rect.width / outputSize.width : 1 }

    public func viewPoint(_ point: DevelopSettings.MaskPoint) -> CGPoint {
        let source = CGPoint(x: CGFloat(point.x) * sourceSize.width, y: CGFloat(point.y) * sourceSize.height)
        let output = crop.outputPoint(fromSource: source, sourceSize: sourceSize)
        return CGPoint(x: rect.minX + output.x * viewScale, y: rect.minY + output.y * viewScale)
    }

    public func maskPoint(_ view: CGPoint) -> DevelopSettings.MaskPoint {
        let output = CGPoint(x: (view.x - rect.minX) / viewScale, y: (view.y - rect.minY) / viewScale)
        let source = crop.sourcePoint(fromOutput: output, sourceSize: sourceSize)
        return DevelopSettings.MaskPoint(x: Double(source.x / max(1, sourceSize.width)),
                                         y: Double(source.y / max(1, sourceSize.height)))
    }

    /// A mask length (fraction of the long edge) in view points.
    public func viewLength(_ length: Double) -> CGFloat { CGFloat(length) * longEdge * viewScale }

    /// A view length as a mask length.
    public func maskLength(_ length: CGFloat) -> Double { Double(length / max(0.0001, longEdge * viewScale)) }

    /// A mask point as source pixels, top-left origin; directions measured here are the ones
    /// the gradients store.
    public func sourcePixels(_ point: DevelopSettings.MaskPoint) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * sourceSize.width, y: CGFloat(point.y) * sourceSize.height)
    }

    /// The ellipse of a radial gradient in the view: its center and the ends of its two
    /// half-axes (along its angle, then a quarter turn clockwise).
    public func ellipse(_ gradient: DevelopSettings.RadialGradient) -> (center: CGPoint, u: CGPoint, v: CGPoint) {
        let center = viewPoint(gradient.center)
        let radians = gradient.angle * .pi / 180
        let c = sourcePixels(gradient.center)
        let rx = CGFloat(gradient.radiusX) * longEdge, ry = CGFloat(gradient.radiusY) * longEdge
        let uSource = CGPoint(x: c.x + rx * CGFloat(cos(radians)), y: c.y + rx * CGFloat(sin(radians)))
        let vSource = CGPoint(x: c.x - ry * CGFloat(sin(radians)), y: c.y + ry * CGFloat(cos(radians)))
        return (center, viewPoint(fromSourcePixels: uSource), viewPoint(fromSourcePixels: vSource))
    }

    public func viewPoint(fromSourcePixels source: CGPoint) -> CGPoint {
        let output = crop.outputPoint(fromSource: source, sourceSize: sourceSize)
        return CGPoint(x: rect.minX + output.x * viewScale, y: rect.minY + output.y * viewScale)
    }

    public func sourcePixels(fromView view: CGPoint) -> CGPoint {
        let output = CGPoint(x: (view.x - rect.minX) / viewScale, y: (view.y - rect.minY) / viewScale)
        return crop.sourcePoint(fromOutput: output, sourceSize: sourceSize)
    }

    /// A radial gradient whose ellipse, in the view, is centered at `center` with half-axes
    /// `width` and `height` along the view's axes.
    public func radial(center: CGPoint, width: CGFloat, height: CGFloat, feather: Double) -> DevelopSettings.RadialGradient {
        let c = sourcePixels(fromView: center)
        let u = sourcePixels(fromView: CGPoint(x: center.x + max(width, 1), y: center.y))
        let v = sourcePixels(fromView: CGPoint(x: center.x, y: center.y + max(height, 1)))
        let angle = atan2(Double(u.y - c.y), Double(u.x - c.x)) * 180 / .pi
        return DevelopSettings.RadialGradient(center: maskPoint(center),
                                              radiusX: Double(hypot(u.x - c.x, u.y - c.y) / longEdge),
                                              radiusY: Double(hypot(v.x - c.x, v.y - c.y) / longEdge),
                                              angle: angle, feather: feather)
    }
}
