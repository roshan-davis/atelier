import CoreGraphics
import Foundation

/// A small SVG reader and painter for flat vector art: the built-in Match Look references and
/// other studies drawn in solid colors. It understands the shapes such art uses (rect, circle,
/// ellipse, line, polygon, polyline and path with M, L, H, V, C, S, Q, T and Z, absolute or
/// relative), solid fills and strokes given as #rgb or #rrggbb, opacity, stroke width and round
/// line caps, `g` groups with a translate, and a `data-part` name on any shape (inherited from its
/// group), so a drawing can say which shapes are skin, hair or clothes. Gradients, text, filters
/// and CSS are not read. Immutable once read, so it is safe to share between threads.
public struct FlatSVG: @unchecked Sendable {
    public struct Shape: @unchecked Sendable {
        public var path: CGPath
        public var fill: CGColor?
        public var stroke: CGColor?
        public var strokeWidth: CGFloat
        public var roundCaps: Bool
        public var opacity: CGFloat
        public var part: String?
    }

    /// The drawing's own coordinate box (its viewBox).
    public let viewBox: CGRect
    /// Shapes in painting order.
    public let shapes: [Shape]

    public init?(data: Data) {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let box = reader.viewBox, box.width > 0, box.height > 0 else { return nil }
        viewBox = box
        shapes = reader.shapes
    }

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    /// The parts named with `data-part`.
    public var parts: Set<String> { Set(shapes.compactMap(\.part)) }

    /// `width` pixels wide, the height following the viewBox, in sRGB.
    public func image(width: Int) -> CGImage? {
        draw(width: width) { context, shape in
            Self.paint(shape, in: context, fill: shape.fill, stroke: shape.stroke, opacity: shape.opacity)
        }
    }

    /// A gray mask, white where the shapes named `parts` show and black elsewhere: every shape is
    /// painted in order, the named ones white and the rest black at their own opacity, so a part
    /// hidden behind a later shape is left out, as it is in the picture.
    public func mask(parts: Set<String>, width: Int) -> CGImage? {
        let white = CGColor(gray: 1, alpha: 1)
        let black = CGColor(gray: 0, alpha: 1)
        return draw(width: width, gray: true) { context, shape in
            let color = shape.part.map { parts.contains($0) } == true ? white : black
            Self.paint(shape, in: context, fill: shape.fill == nil ? nil : color,
                       stroke: shape.stroke == nil ? nil : color, opacity: shape.opacity)
        }
    }

    /// The drawing's height in pixels at `width`.
    public func height(forWidth width: Int) -> Int {
        max(1, Int((CGFloat(width) * viewBox.height / viewBox.width).rounded()))
    }

    private func draw(width: Int, gray: Bool = false, _ each: (CGContext, Shape) -> Void) -> CGImage? {
        let height = self.height(forWidth: width)
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)
        let info = gray ? CGImageAlphaInfo.none : CGImageAlphaInfo.noneSkipLast
        guard width > 0, let space,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // SVG's y axis points down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / viewBox.width, y: -CGFloat(height) / viewBox.height)
        context.translateBy(x: -viewBox.minX, y: -viewBox.minY)
        context.setShouldAntialias(true)
        for shape in shapes { each(context, shape) }
        return context.makeImage()
    }

    private static func paint(_ shape: Shape, in context: CGContext, fill: CGColor?, stroke: CGColor?, opacity: CGFloat) {
        context.saveGState()
        context.setAlpha(opacity)
        if let fill {
            context.addPath(shape.path)
            context.setFillColor(fill)
            context.fillPath()
        }
        if let stroke, shape.strokeWidth > 0 {
            context.addPath(shape.path)
            context.setStrokeColor(stroke)
            context.setLineWidth(shape.strokeWidth)
            context.setLineCap(shape.roundCaps ? .round : .butt)
            context.setLineJoin(.round)
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: Reading

    private final class Reader: NSObject, XMLParserDelegate {
        var viewBox: CGRect?
        var shapes: [Shape] = []
        /// Each open `svg` or `g` element: its offset, part and fill, which the shapes inside inherit.
        private var groups: [(offset: CGPoint, part: String?, fill: String?)] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            let part = a["data-part"] ?? groups.last?.part
            let fill = a["fill"] ?? groups.last?.fill
            switch name {
            case "svg":
                let numbers = FlatSVG.numbers(a["viewBox"] ?? "")
                if numbers.count == 4 {
                    viewBox = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
                } else if let w = a["width"].flatMap({ Double($0) }), let h = a["height"].flatMap({ Double($0) }) {
                    viewBox = CGRect(x: 0, y: 0, width: w, height: h)
                }
                groups.append((.zero, part, fill))
            case "g":
                groups.append((FlatSVG.translation(a["transform"]), part, fill))
            default:
                guard var path = FlatSVG.path(name, a) else { return }
                var offset = FlatSVG.translation(a["transform"])
                for group in groups {
                    offset.x += group.offset.x
                    offset.y += group.offset.y
                }
                if offset != .zero {
                    var move = CGAffineTransform(translationX: offset.x, y: offset.y)
                    path = path.copy(using: &move) ?? path
                }
                // SVG fills shapes black unless told otherwise; a line has no inside to fill.
                let fillColor: CGColor?
                if name == "line" {
                    fillColor = nil
                } else if let fill {
                    fillColor = FlatSVG.color(fill)
                } else {
                    fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                }
                let width = a["stroke-width"].flatMap { Double($0) } ?? 1
                let opacity = a["opacity"].flatMap { Double($0) } ?? 1
                shapes.append(Shape(path: path, fill: fillColor,
                                    stroke: a["stroke"].flatMap { FlatSVG.color($0) },
                                    strokeWidth: CGFloat(width),
                                    roundCaps: a["stroke-linecap"] == "round",
                                    opacity: CGFloat(opacity),
                                    part: part))
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "g" || name == "svg", !groups.isEmpty { groups.removeLast() }
        }
    }

    /// A shape element as a path in its own coordinates; nil for anything else.
    static func path(_ name: String, _ a: [String: String]) -> CGPath? {
        func value(_ key: String) -> CGFloat { CGFloat(a[key].flatMap { Double($0) } ?? 0) }
        let path = CGMutablePath()
        switch name {
        case "rect":
            let rect = CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
            guard rect.width > 0, rect.height > 0 else { return nil }
            let rx = a["rx"] != nil ? value("rx") : value("ry"), ry = a["ry"] != nil ? value("ry") : rx
            if rx > 0 || ry > 0 {
                path.addRoundedRect(in: rect, cornerWidth: min(rx, rect.width / 2), cornerHeight: min(ry, rect.height / 2))
            } else {
                path.addRect(rect)
            }
        case "circle":
            let r = value("r")
            guard r > 0 else { return nil }
            path.addEllipse(in: CGRect(x: value("cx") - r, y: value("cy") - r, width: 2 * r, height: 2 * r))
        case "ellipse":
            let rx = value("rx"), ry = value("ry")
            guard rx > 0, ry > 0 else { return nil }
            path.addEllipse(in: CGRect(x: value("cx") - rx, y: value("cy") - ry, width: 2 * rx, height: 2 * ry))
        case "line":
            path.move(to: CGPoint(x: value("x1"), y: value("y1")))
            path.addLine(to: CGPoint(x: value("x2"), y: value("y2")))
        case "polygon", "polyline":
            let n = numbers(a["points"] ?? "")
            guard n.count >= 4 else { return nil }
            path.move(to: CGPoint(x: n[0], y: n[1]))
            for i in stride(from: 2, to: n.count - 1, by: 2) { path.addLine(to: CGPoint(x: n[i], y: n[i + 1])) }
            if name == "polygon" { path.closeSubpath() }
        case "path":
            guard let d = a["d"], let parsed = pathData(d) else { return nil }
            return parsed
        default:
            return nil
        }
        return path
    }

    /// SVG path data (M, L, H, V, C, S, Q, T, Z in either case; arcs are not read).
    static func pathData(_ d: String) -> CGPath? {
        let path = CGMutablePath()
        var tokens: [Character] = []
        var values: [[Double]] = []
        // Split into commands and their numbers.
        var current: [Double] = []
        var number = ""
        func flushNumber() {
            if let v = Double(number) { current.append(v) }
            number = ""
        }
        for ch in d {
            if ch.isLetter, ch != "e", ch != "E" {
                flushNumber()
                if !tokens.isEmpty { values.append(current) }
                current = []
                tokens.append(ch)
            } else if ch == "-" && !number.isEmpty && number.last != "e" && number.last != "E" {
                flushNumber()
                number = "-"
            } else if ch == "." && number.contains(".") {
                flushNumber()
                number = "."
            } else if ch.isNumber || ch == "." || ch == "-" || ch == "e" || ch == "E" || ch == "+" {
                number.append(ch)
            } else {
                flushNumber()
            }
        }
        flushNumber()
        if !tokens.isEmpty { values.append(current) }
        guard tokens.count == values.count else { return nil }

        var point = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuad: CGPoint?
        for (command, v) in zip(tokens, values) {
            let relative = command.isLowercase
            func at(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: point.x + x, y: point.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased() {
            case "M":
                var i = 0
                while i + 1 < v.count {
                    let p = at(v[i], v[i + 1])
                    if i == 0 { path.move(to: p); start = p } else { path.addLine(to: p) }
                    point = p
                    i += 2
                }
                lastControl = nil; lastQuad = nil
            case "L":
                var i = 0
                while i + 1 < v.count {
                    point = at(v[i], v[i + 1])
                    path.addLine(to: point)
                    i += 2
                }
                lastControl = nil; lastQuad = nil
            case "H":
                for x in v {
                    point = CGPoint(x: relative ? point.x + x : x, y: point.y)
                    path.addLine(to: point)
                }
                lastControl = nil; lastQuad = nil
            case "V":
                for y in v {
                    point = CGPoint(x: point.x, y: relative ? point.y + y : y)
                    path.addLine(to: point)
                }
                lastControl = nil; lastQuad = nil
            case "C":
                var i = 0
                while i + 5 < v.count {
                    let c1 = at(v[i], v[i + 1]), c2 = at(v[i + 2], v[i + 3]), p = at(v[i + 4], v[i + 5])
                    path.addCurve(to: p, control1: c1, control2: c2)
                    lastControl = c2
                    point = p
                    i += 6
                }
                lastQuad = nil
            case "S":
                var i = 0
                while i + 3 < v.count {
                    let c1 = lastControl.map { CGPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point
                    let c2 = at(v[i], v[i + 1]), p = at(v[i + 2], v[i + 3])
                    path.addCurve(to: p, control1: c1, control2: c2)
                    lastControl = c2
                    point = p
                    i += 4
                }
                lastQuad = nil
            case "Q":
                var i = 0
                while i + 3 < v.count {
                    let c = at(v[i], v[i + 1]), p = at(v[i + 2], v[i + 3])
                    path.addQuadCurve(to: p, control: c)
                    lastQuad = c
                    point = p
                    i += 4
                }
                lastControl = nil
            case "T":
                var i = 0
                while i + 1 < v.count {
                    let c = lastQuad.map { CGPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point
                    let p = at(v[i], v[i + 1])
                    path.addQuadCurve(to: p, control: c)
                    lastQuad = c
                    point = p
                    i += 2
                }
                lastControl = nil
            case "Z":
                path.closeSubpath()
                point = start
                lastControl = nil; lastQuad = nil
            default:
                // Arcs and anything else are not read.
                return nil
            }
        }
        return path
    }

    /// The numbers in a list separated by spaces or commas.
    static func numbers(_ text: String) -> [Double] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).compactMap { Double($0) }
    }

    /// `translate(x, y)` (or `translate(x)`); zero for anything else.
    static func translation(_ transform: String?) -> CGPoint {
        guard let transform, let open = transform.range(of: "translate("),
              let close = transform[open.upperBound...].firstIndex(of: ")") else { return .zero }
        let n = numbers(String(transform[open.upperBound..<close]))
        return CGPoint(x: n.first ?? 0, y: n.count > 1 ? n[1] : 0)
    }

    /// `#rgb` or `#rrggbb`; nil for `none` and anything else.
    static func color(_ text: String) -> CGColor? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
