import CoreGraphics

/// Original color studies. The same sRGB artwork supplies the picker and the ordinary image fit.
enum BuiltInLookReference: String, CaseIterable, Identifiable {
    case matrixPortrait, matrixCity, thronesPortrait, thronesLandscape
    case furyRoadPortrait, furyRoadScene, darkKnightPortrait, darkKnightCity

    enum Theme: String, CaseIterable, Identifiable {
        case matrix = "The Matrix"
        case thrones = "Game of Thrones"
        case furyRoad = "Mad Max: Fury Road"
        case darkKnight = "The Dark Knight"
        var id: Self { self }
    }

    enum Scene: String {
        case portrait = "Portrait"
        case urbanNight = "Urban Night"
        case winterLandscape = "Winter Landscape"
        case desertAction = "Desert Action"
    }

    var id: Self { self }

    var theme: Theme {
        switch self {
        case .matrixPortrait, .matrixCity: return .matrix
        case .thronesPortrait, .thronesLandscape: return .thrones
        case .furyRoadPortrait, .furyRoadScene: return .furyRoad
        case .darkKnightPortrait, .darkKnightCity: return .darkKnight
        }
    }

    var scene: Scene {
        switch self {
        case .matrixPortrait, .thronesPortrait, .furyRoadPortrait, .darkKnightPortrait: return .portrait
        case .matrixCity, .darkKnightCity: return .urbanNight
        case .thronesLandscape: return .winterLandscape
        case .furyRoadScene: return .desertAction
        }
    }

    var name: String { "\(theme.rawValue) — \(scene.rawValue)" }

    var palette: String {
        switch self {
        case .matrixPortrait: return "Olive light, moss and graphite."
        case .matrixCity: return "Jade glass and silver-green lights."
        case .thronesPortrait: return "Frost blue, slate and warm skin."
        case .thronesLandscape: return "Pale snow, slate and pine."
        case .furyRoadPortrait: return "Copper light, teal and sand."
        case .furyRoadScene: return "Burnt orange dust and cyan sky."
        case .darkKnightPortrait: return "Amber light, steel and ink."
        case .darkKnightCity: return "Blue slate and amber windows."
        }
    }

    /// The main color-bearing parts of the composition, shown as a guide in the picker.
    var regions: String {
        switch scene {
        case .portrait: return "Face & Skin\nClothing · Background"
        case .urbanNight: return "Sky · Buildings · Street"
        case .winterLandscape: return "Sky · Snow · Ground"
        case .desertAction: return "Sky · Dust · Ground"
        }
    }

    /// Cheek and lower face swatches on the 120 × 80 drawing. Wide studies have no skin sample.
    var skinRegions: [CGRect] {
        let swatch: CGRect
        switch self {
        case .matrixPortrait: swatch = CGRect(x: 67, y: 38, width: 9, height: 6)
        case .thronesPortrait: swatch = CGRect(x: 52, y: 39, width: 9, height: 8)
        case .furyRoadPortrait: swatch = CGRect(x: 65, y: 38, width: 10, height: 9)
        case .darkKnightPortrait: swatch = CGRect(x: 63, y: 38, width: 9, height: 9)
        default: return []
        }
        return [CGRect(x: swatch.minX / 120, y: swatch.minY / 80,
                       width: swatch.width / 120, height: swatch.height / 80)]
    }

    func image(width: Int = 960) -> CGImage? {
        let height = width * 2 / 3
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / 120, y: -CGFloat(height) / 80)
        let art = StudyCanvas(context: context, light: light)
        switch self {
        case .matrixPortrait: drawMatrixPortrait(art)
        case .matrixCity: drawMatrixCity(art)
        case .thronesPortrait: drawWinterPortrait(art)
        case .thronesLandscape: drawWinterLandscape(art)
        case .furyRoadPortrait: drawDustPortrait(art)
        case .furyRoadScene: drawDustRun(art)
        case .darkKnightPortrait: drawNightPortrait(art)
        case .darkKnightCity: drawNightCity(art)
        }
        StudyCanvas.dither(context)
        return context.makeImage()
    }

    /// Where the key light comes from and the colors light and shade take in this look, so every
    /// surface carries the grade the same way: lit sides lean to `glow`, shaded sides to `shade`.
    private var light: StudyLight {
        switch theme {
        case .matrix: return StudyLight(dx: 0.6, dy: -0.8, glow: 0xdfe6b4, shade: 0x0c2a22)
        case .thrones: return StudyLight(dx: 0.55, dy: -0.85, glow: 0xf3e4c9, shade: 0x172d42)
        case .furyRoad: return StudyLight(dx: -0.6, dy: -0.8, glow: 0xffcf8f, shade: 0x0b3a40)
        case .darkKnight: return StudyLight(dx: 0.6, dy: -0.8, glow: 0xffc074, shade: 0x0b1828)
        }
    }
}


/// The key light of a study: its direction (toward the light, y down) and the colors the lit
/// and shaded sides of every surface lean to.
struct StudyLight {
    let dx: CGFloat
    let dy: CGFloat
    let glow: UInt32
    let shade: UInt32
}

// Coordinates are in a 120 × 80 canvas with the origin at the top left. Broad fields set the
// palette's proportions. Every shape is drawn as a smooth curve through its points and shaded
// from its lit side to its shaded side, so light and shadow carry the look's colors on every
// surface. Small near-black accents and soft glints give each study a full tonal range.
private struct StudyCanvas {
    typealias Point = (CGFloat, CGFloat)
    let context: CGContext
    let light: StudyLight

    /// A rounded shape through the points. Points on the canvas edge stay corners, so fields
    /// still reach the frame.
    func shape(_ color: UInt32, _ first: Point, _ rest: Point...) {
        paint(smooth([first] + rest), color)
    }

    /// A shape with straight sides, for buildings, roads and trees.
    func facet(_ color: UInt32, _ first: Point, _ rest: Point...) {
        paint(straight([first] + rest), color)
    }

    func rect(_ color: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        paint(CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil), color)
    }

    /// A rounded form lit like a sphere: brightest toward the light, falling off to its shaded side.
    func ellipse(_ color: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        let box = CGRect(x: x, y: y, width: w, height: h)
        let center = CGPoint(x: box.midX, y: box.midY), radius = max(w, h) / 2
        let hot = CGPoint(x: center.x + light.dx * radius * 0.45, y: center.y + light.dy * radius * 0.45)
        context.saveGState()
        context.addEllipse(in: box)
        context.clip()
        context.drawRadialGradient(gradient(color), startCenter: hot, startRadius: 0, endCenter: center,
                                   endRadius: radius * 1.05, options: [.drawsAfterEndLocation])
        context.restoreGState()
    }

    /// The deepest shadow: close to black, leaning to the look's shade color.
    func deep(_ first: Point, _ rest: Point...) {
        context.setFillColor(Self.cgColor(Self.mix(Self.rgb(light.shade), .zero, 0.82)))
        context.addPath(smooth([first] + rest))
        context.fillPath()
    }

    /// A soft glint, close to white and leaning to the look's light color.
    func spark(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        let white = Self.mix(Self.rgb(light.glow), SIMD3(1, 1, 1), 0.7)
        let colors = [Self.cgColor(white), Self.cgColor(white, alpha: 0)] as CFArray
        guard let glint = CGGradient(colorsSpace: Self.space, colors: colors, locations: [0, 1]) else { return }
        let box = CGRect(x: x, y: y, width: w, height: h)
        context.saveGState()
        context.translateBy(x: box.midX, y: box.midY)
        context.scaleBy(x: w / 2, y: h / 2)
        context.drawRadialGradient(glint, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
    }

    func sky(_ top: UInt32, _ bottom: UInt32) {
        let colors = [Self.cgColor(lit(Self.rgb(top))), Self.cgColor(Self.rgb(top)), Self.cgColor(Self.rgb(bottom))] as CFArray
        guard let gradient = CGGradient(colorsSpace: Self.space, colors: colors, locations: [0, 0.3, 1]) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 80), options: [])
    }

    /// Faint grain (about ±2 levels), so brightness and color are continuous, not a few spikes.
    static func dither(_ context: CGContext) {
        guard let data = context.data, context.bitsPerPixel == 32 else { return }
        let width = context.width, height = context.height, row = context.bytesPerRow
        let bytes = data.bindMemory(to: UInt8.self, capacity: row * height)
        for y in 0..<height {
            for x in 0..<width {
                var h = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
                h ^= h >> 13
                h = h &* 0x5bd1_e995
                h ^= h >> 15
                let noise = max(-2, min(2, Int(h & 3) - Int((h >> 2) & 3)))
                let offset = y * row + x * 4
                for channel in 0..<3 {
                    bytes[offset + channel] = UInt8(max(0, min(255, Int(bytes[offset + channel]) + noise)))
                }
            }
        }
    }

    // MARK: Paths and light

    private func paint(_ path: CGPath, _ hex: UInt32) {
        let box = path.boundingBox
        let center = CGPoint(x: box.midX, y: box.midY)
        let reach = (abs(light.dx) * box.width + abs(light.dy) * box.height) / 2
        let start = CGPoint(x: center.x + light.dx * reach, y: center.y + light.dy * reach)
        let end = CGPoint(x: center.x - light.dx * reach, y: center.y - light.dy * reach)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient(hex), start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// Lit side, the base color near the lit side, shaded side (so most of a surface turns to shade).
    private func gradient(_ hex: UInt32) -> CGGradient {
        let base = Self.rgb(hex)
        let colors = [Self.cgColor(lit(base)), Self.cgColor(base), Self.cgColor(shaded(base))] as CFArray
        return CGGradient(colorsSpace: Self.space, colors: colors, locations: [0, 0.3, 1])!
    }

    private func lit(_ color: SIMD3<Double>) -> SIMD3<Double> {
        Self.mix(color, Self.rgb(light.glow), 0.3) * 1.18 + 0.03
    }

    private func shaded(_ color: SIMD3<Double>) -> SIMD3<Double> {
        Self.mix(color, Self.rgb(light.shade), 0.45) * 0.5
    }

    /// Catmull-Rom through the points, closed. A point on the canvas edge keeps a sharp corner.
    private func smooth(_ points: [Point]) -> CGPath {
        let p = points.map { CGPoint(x: $0.0, y: $0.1) }
        let n = p.count
        guard n > 2 else { return straight(points) }
        func onEdge(_ q: CGPoint) -> Bool { q.x <= 0 || q.x >= 120 || q.y <= 0 || q.y >= 80 }
        let k: CGFloat = 0.85 / 6
        let path = CGMutablePath()
        path.move(to: p[0])
        for i in 0..<n {
            let p0 = p[(i + n - 1) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            let c1 = onEdge(p1) ? p1 : CGPoint(x: p1.x + (p2.x - p0.x) * k, y: p1.y + (p2.y - p0.y) * k)
            let c2 = onEdge(p2) ? p2 : CGPoint(x: p2.x - (p3.x - p1.x) * k, y: p2.y - (p3.y - p1.y) * k)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    private func straight(_ points: [Point]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(Double(hex >> 16), Double((hex >> 8) & 255), Double(hex & 255)) / 255
    }

    private static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }

    private static func cgColor(_ c: SIMD3<Double>, alpha: CGFloat = 1) -> CGColor {
        let v = c.clamped(lowerBound: .zero, upperBound: SIMD3(1, 1, 1))
        return CGColor(srgbRed: v.x, green: v.y, blue: v.z, alpha: alpha)
    }
}

private func drawDustRun(_ a: StudyCanvas) {
    a.sky(0x4c8799, 0xbdd1cc)
    a.spark(4, 2, 22, 16)
    a.shape(0xa4c2c3, (13, 20), (24, 16), (40, 17), (52, 14), (63, 16), (49, 20), (30, 21))
    a.shape(0xc2cebd, (42, 29), (55, 25), (71, 26), (88, 20), (95, 21), (79, 27), (61, 30))
    a.shape(0x9a806e, (0, 36), (17, 26), (30, 31), (36, 38), (69, 36), (98, 24), (120, 24), (120, 80), (0, 80))
    a.shape(0xb87952, (0, 41), (18, 35), (38, 40), (66, 38), (92, 31), (120, 35), (120, 80), (0, 80))
    a.shape(0xc99364, (0, 48), (27, 43), (44, 46), (68, 41), (92, 43), (120, 39), (120, 80), (0, 80))
    a.shape(0xae7655, (0, 66), (25, 55), (53, 58), (78, 49), (120, 45), (120, 80), (0, 80))
    a.shape(0x83543f, (0, 80), (25, 66), (50, 65), (80, 54), (103, 52), (81, 59), (55, 73), (45, 80))
    a.shape(0xdba773, (5, 62), (30, 53), (50, 53), (63, 46), (86, 46), (69, 53), (43, 59))
    a.shape(0xe1b88e, (24, 58), (45, 51), (71, 48), (81, 46), (75, 51), (47, 55))
    a.deep((0, 80), (0, 70), (18, 66), (34, 74), (40, 80))
    a.deep((70, 58), (84, 56), (102, 51), (104, 55), (76, 62))
    a.ellipse(0x373231, 72, 51, 10, 9)
    a.ellipse(0x373231, 91, 48, 9, 9)
    a.shape(0x4e4038, (70, 51), (78, 47), (82, 41), (91, 39), (96, 44), (102, 44), (102, 50), (72, 56))
    a.shape(0x7f827b, (82, 46), (85, 42), (91, 41), (94, 44))
    a.rect(0xeac69a, 97, 46, 4, 2)
    a.spark(96, 44.5, 5, 3)
    a.spark(86, 41, 4, 2)
}

private func drawMatrixPortrait(_ a: StudyCanvas) {
    // Background: deep green glass, lit vertical mullions and a misty reflection.
    a.sky(0x293c37, 0x7c8b66)
    a.facet(0x374842, (0, 0), (30, 0), (13, 80), (0, 80))
    a.facet(0x60755c, (34, 0), (45, 0), (25, 80), (16, 80))
    a.facet(0x91a188, (38, 0), (41, 0), (21, 80), (19, 80))
    a.facet(0x425c4f, (92, 0), (120, 0), (120, 80), (83, 80))
    a.facet(0x78947a, (92, 1), (102, 1), (94, 80), (90, 80))
    a.shape(0xaeb89c, (106, 26), (120, 20), (120, 25), (105, 30))
    a.deep((0, 38), (7, 34), (10, 80), (0, 80))
    a.spark(37, 2, 3, 16)
    // Clothing: graphite with reflected green on the shoulder and lapel.
    a.shape(0x262d2d, (19, 80), (35, 64), (60, 53), (79, 55), (107, 65), (117, 80))
    a.shape(0x46524b, (19, 80), (35, 64), (53, 58), (61, 68), (46, 80))
    a.shape(0x5d6e5e, (60, 54), (70, 63), (65, 76), (51, 63))
    a.shape(0x37413d, (78, 57), (89, 61), (76, 72), (69, 80))
    a.deep((48, 66), (54, 62), (58, 68), (52, 78), (44, 80), (38, 80))
    a.deep((84, 66), (98, 68), (110, 80), (80, 80))
    // Face and skin: olive bounce light and warm brown planes.
    a.ellipse(0x273230, 52, 13, 33, 36)
    a.shape(0x775e4e, (62, 41), (77, 40), (79, 57), (71, 64), (58, 58))
    a.shape(0xb79a73, (59, 28), (70, 22), (81, 26), (84, 37), (82, 43), (77, 51), (67, 52), (57, 43))
    a.shape(0x8c7457, (59, 28), (65, 34), (64, 43), (70, 52), (66, 52), (57, 43))
    a.shape(0xc7b690, (75, 27), (81, 26), (84, 37), (87, 41), (80, 42), (77, 38))
    a.shape(0x4f5143, (69, 34), (77, 33), (77, 35), (70, 36))
    a.shape(0x685142, (75, 45), (81, 44), (78, 47))
    a.shape(0x36463f, (52, 30), (53, 22), (60, 15), (73, 15), (80, 22), (69, 22), (60, 27), (57, 39))
    a.spark(74.5, 33.6, 1.4, 1.2)
    a.spark(80, 26, 4, 3)
}

private func drawMatrixCity(_ a: StudyCanvas) {
    a.sky(0x23332f, 0x8d9c83)
    a.shape(0x607265, (0, 31), (11, 28), (20, 35), (34, 36), (48, 46), (79, 41),
            (90, 35), (106, 32), (120, 29), (120, 80), (0, 80))
    a.facet(0x283b36, (0, 7), (28, 19), (32, 51), (0, 76))
    a.facet(0x3b5145, (0, 14), (13, 20), (15, 59), (0, 71))
    a.facet(0x455e52, (120, 0), (88, 17), (87, 47), (120, 70))
    a.facet(0x668273, (120, 11), (103, 20), (101, 55), (120, 65))
    a.facet(0x354f44, (81, 27), (72, 32), (71, 45), (81, 49))
    a.facet(0x839785, (43, 29), (49, 34), (50, 46), (45, 49))
    for y in [CGFloat(29), 37, 45, 53] {
        a.facet(0x879f80, (5, y - 2), (11, y), (11, y + 2), (5, y + 1))
        a.facet(0xa9bc9d, (107, y), (115, y - 3), (115, y + 1), (107, y + 3))
    }
    a.facet(0x374943, (0, 74), (47, 45), (72, 45), (120, 68), (120, 80), (0, 80))
    a.facet(0x5f7768, (9, 80), (51, 48), (69, 46), (54, 80))
    a.facet(0x92a694, (31, 80), (56, 49), (61, 49), (55, 57), (59, 61), (50, 80))
    a.facet(0x728d7b, (75, 58), (82, 59), (113, 75), (104, 80), (90, 66))
    a.deep((0, 80), (0, 76), (16, 66), (24, 80))
    a.deep((104, 80), (113, 75), (120, 72), (120, 80))
    a.facet(0xd1d9bb, (54, 44), (67, 44), (66, 46), (54, 47))
    a.spark(56, 42.5, 9, 4)
    a.shape(0x303936, (81, 61), (85, 59), (90, 59), (94, 61), (94, 66), (82, 66))
    a.rect(0xc0c7a5, 83, 62, 3, 1)
    a.rect(0xc0c7a5, 89, 62, 3, 1)
    a.spark(83, 61.5, 3, 2)
    a.spark(89, 61.5, 3, 2)
}

private func drawWinterPortrait(_ a: StudyCanvas) {
    a.sky(0x789099, 0xb7c8c4)
    a.shape(0x879fa5, (0, 32), (21, 16), (41, 28), (66, 19), (90, 34), (120, 21), (120, 80), (0, 80))
    a.shape(0xa5b6b8, (0, 39), (21, 16), (34, 25), (23, 24), (17, 28), (13, 27))
    a.spark(17, 15, 8, 5)
    a.shape(0x6a7d80, (0, 48), (25, 37), (44, 44), (77, 35), (120, 40), (120, 80), (0, 80))
    a.shape(0x899c9b, (0, 58), (22, 49), (52, 52), (79, 45), (120, 48), (120, 80), (0, 80))
    a.shape(0x505f63, (4, 80), (15, 67), (32, 59), (54, 57), (80, 61), (93, 80))
    a.shape(0x657477, (4, 80), (15, 67), (32, 59), (45, 69), (32, 80))
    a.shape(0x8c8c85, (20, 68), (29, 60), (37, 59), (42, 55), (56, 57), (68, 55),
            (78, 62), (72, 68), (62, 65), (51, 72), (44, 68), (33, 72))
    a.shape(0x3a484e, (51, 73), (62, 65), (73, 68), (82, 65), (93, 80), (45, 80))
    a.deep((52, 80), (62, 70), (78, 71), (90, 80))
    a.deep((4, 80), (11, 71), (24, 80))
    a.ellipse(0x4d4a45, 36, 14, 35, 40)
    a.deep((36, 32), (40, 25), (43, 44), (38, 47))
    a.shape(0x886f62, (45, 42), (62, 43), (62, 57), (53, 64), (42, 57))
    a.shape(0xc09a83, (45, 24), (56, 21), (64, 26), (67, 33), (72, 40), (66, 42), (63, 51), (54, 54), (44, 46))
    a.shape(0x9e7c6d, (44, 28), (50, 31), (48, 40), (53, 49), (62, 51), (54, 54), (44, 46))
    a.shape(0xd9b499, (60, 24), (64, 26), (67, 33), (72, 40), (65, 39), (61, 34))
    a.shape(0x61564f, (57, 34), (65, 34), (62, 36), (57, 36))
    a.shape(0x605651, (35, 23), (46, 16), (58, 16), (64, 23), (53, 22), (48, 29), (44, 46), (38, 45))
    a.spark(62.6, 34.4, 1.3, 1.1)
    a.spark(65, 27, 3, 4)
}

private func drawWinterLandscape(_ a: StudyCanvas) {
    a.sky(0x859aa5, 0xc7d2cc)
    a.shape(0xa6b8be, (0, 37), (16, 24), (24, 27), (44, 16), (55, 26), (77, 21), (99, 34),
            (112, 26), (120, 31), (120, 80), (0, 80))
    a.shape(0x718890, (0, 43), (16, 35), (35, 40), (57, 25), (71, 36), (80, 33), (120, 43), (120, 80), (0, 80))
    a.shape(0xcbd4cf, (43, 35), (57, 25), (71, 36), (63, 34), (60, 30), (54, 34), (50, 32))
    a.spark(55, 24.5, 5, 3)
    a.shape(0x9bafb0, (0, 53), (25, 42), (39, 45), (70, 42), (93, 48), (120, 42), (120, 80), (0, 80))
    a.shape(0xc2cfcd, (0, 66), (29, 54), (54, 56), (87, 50), (120, 53), (120, 80), (0, 80))
    // A small unadorned gatehouse against snow, with pine in the foreground.
    a.rect(0x546467, 85, 46, 16, 9)
    a.rect(0x687779, 87, 40, 5, 14)
    a.rect(0x738181, 97, 42, 5, 14)
    a.facet(0x869595, (85, 41), (90, 37), (94, 41))
    a.deep((88.5, 55), (88.5, 50), (91.5, 50), (91.5, 55))
    a.rect(0xb6a07c, 93, 49, 2, 3)
    a.spark(92.5, 48.5, 3, 4)
    a.shape(0x728c90, (0, 70), (29, 60), (51, 63), (71, 58), (90, 60), (120, 56), (120, 80), (0, 80))
    a.shape(0xa9bec0, (0, 75), (33, 68), (56, 71), (86, 63), (120, 62), (120, 80), (0, 80))
    a.spark(96, 61, 14, 3)
    for (x, y, height) in [(5.0, 79.0, 20.0), (14, 78, 13), (22, 80, 17), (109, 76, 10), (116, 77, 17)] {
        a.facet(0x455d5c, (x - height / 4, y), (x, y - height), (x + height / 4, y))
    }
    a.deep((0, 80), (0, 74), (14, 73), (30, 80))
    a.deep((104, 80), (110, 75), (120, 74), (120, 80))
}

private func drawDustPortrait(_ a: StudyCanvas) {
    a.sky(0x5c8994, 0xc1c1a3)
    a.spark(6, 3, 24, 16)
    a.shape(0x9e9b80, (0, 32), (31, 26), (45, 31), (73, 30), (94, 22), (120, 27), (120, 80), (0, 80))
    a.shape(0xc59c74, (0, 46), (31, 34), (61, 38), (84, 32), (120, 31), (120, 80), (0, 80))
    a.shape(0xb68464, (0, 53), (26, 42), (50, 46), (83, 40), (120, 42), (120, 80), (0, 80))
    a.shape(0xd5ab7d, (0, 64), (25, 58), (57, 52), (84, 56), (120, 49), (120, 80), (0, 80))
    a.shape(0x5c625d, (29, 80), (41, 64), (54, 59), (70, 56), (86, 60), (104, 68), (115, 80))
    a.shape(0x8b8a75, (29, 80), (41, 64), (54, 59), (65, 68), (48, 80))
    a.shape(0x374340, (67, 71), (80, 57), (94, 63), (104, 68), (115, 80), (76, 80))
    a.deep((74, 80), (86, 67), (100, 70), (112, 80))
    a.deep((29, 80), (37, 70), (46, 80))
    a.ellipse(0x524a42, 54, 15, 31, 40)
    a.deep((80, 32), (84, 24), (86, 38), (83, 50))
    a.shape(0x9c6f56, (59, 42), (75, 42), (77, 56), (70, 63), (55, 59))
    a.shape(0xc38e66, (59, 28), (69, 24), (80, 27), (84, 39), (81, 48), (72, 54), (61, 50), (57, 43), (52, 41))
    a.shape(0xd9aa7e, (60, 27), (68, 24), (68, 32), (63, 41), (64, 50), (57, 46), (52, 41))
    a.shape(0xa77158, (79, 28), (84, 39), (81, 48), (72, 54), (68, 52), (76, 45))
    a.shape(0x705c50, (60, 35), (67, 34), (68, 36), (60, 37))
    a.shape(0xbda585, (52, 26), (56, 20), (66, 15), (80, 18), (86, 27), (73, 25), (61, 27), (56, 32))
    a.shape(0x8f8975, (57, 54), (66, 57), (75, 56), (80, 59), (69, 67), (54, 63), (49, 60))
    a.spark(61.5, 35, 1.3, 1.1)
    a.spark(58, 17, 6, 4)
}

private func drawNightPortrait(_ a: StudyCanvas) {
    a.sky(0x233442, 0x69747b)
    a.shape(0x354653, (0, 20), (22, 15), (30, 30), (39, 35), (43, 80), (0, 80))
    a.shape(0x4c5d69, (86, 17), (109, 12), (120, 19), (120, 80), (80, 80))
    a.shape(0x778388, (100, 23), (120, 28), (120, 36), (99, 30))
    a.deep((0, 42), (8, 40), (13, 80), (0, 80))
    a.ellipse(0x978474, 13, 27, 9, 10)
    a.ellipse(0xc5a883, 15, 28, 5, 6)
    a.spark(15.5, 29, 3, 3)
    a.ellipse(0x91806b, 94, 48, 14, 14)
    a.ellipse(0xba9772, 97, 50, 8, 8)
    a.spark(99, 52, 4, 4)
    a.shape(0x283340, (21, 80), (31, 65), (50, 57), (73, 56), (94, 64), (108, 80))
    a.shape(0x435463, (21, 80), (31, 65), (48, 58), (58, 68), (40, 80))
    a.shape(0x202b35, (60, 70), (73, 56), (94, 64), (108, 80), (74, 80))
    a.deep((76, 80), (88, 68), (100, 72), (107, 80))
    a.ellipse(0x303841, 47, 15, 31, 36)
    a.shape(0x84665a, (53, 41), (69, 41), (74, 56), (66, 65), (50, 58))
    a.shape(0xb38b71, (55, 25), (69, 23), (75, 31), (76, 38), (81, 42), (75, 45), (72, 51), (63, 54), (53, 47))
    a.shape(0x856a60, (55, 25), (61, 31), (60, 41), (65, 49), (69, 52), (63, 54), (53, 47))
    a.shape(0xd0a586, (69, 23), (75, 31), (76, 38), (81, 42), (74, 41), (70, 36))
    a.shape(0x594e4c, (64, 34), (73, 34), (71, 36), (64, 36))
    a.shape(0x353f46, (45, 31), (47, 22), (57, 16), (69, 17), (74, 23), (61, 23), (55, 27), (53, 43))
    a.spark(70.2, 34.5, 1.2, 1)
    a.spark(73, 26, 3, 4)
}

private func drawNightCity(_ a: StudyCanvas) {
    a.sky(0x263a50, 0x818a91)
    a.shape(0x4e6070, (0, 34), (18, 35), (31, 27), (45, 34), (54, 31), (75, 39),
            (88, 28), (109, 33), (120, 27), (120, 80), (0, 80))
    a.facet(0x324459, (0, 15), (20, 20), (20, 60), (0, 66))
    a.facet(0x46586b, (24, 30), (41, 24), (42, 57), (24, 62))
    a.facet(0x3d5265, (99, 18), (120, 12), (120, 63), (98, 57))
    a.facet(0x617181, (80, 30), (91, 23), (92, 57), (78, 56))
    for y in [CGFloat(32), 40, 48] {
        a.rect(0x997f68, 7, y, 4, 2)
        a.rect(0xc2a17e, 31, y + 1, 4, 2)
        a.rect(0xa7937b, 83, y, 4, 2)
        a.rect(0x9b866e, 108, y - 3, 4, 2)
    }
    a.spark(30.5, 40.5, 5, 3)
    a.spark(107.5, 36.5, 5, 3)
    a.facet(0x263748, (0, 68), (39, 55), (74, 53), (120, 64), (120, 80), (0, 80))
    a.facet(0x667681, (0, 74), (41, 57), (73, 55), (113, 68), (109, 70), (72, 58), (43, 60), (0, 79))
    a.facet(0x485e71, (42, 80), (56, 62), (77, 61), (105, 80))
    a.facet(0x8b8078, (50, 80), (59, 70), (62, 70), (56, 80))
    a.facet(0x848582, (86, 72), (95, 73), (109, 80), (104, 80))
    a.deep((0, 80), (0, 79), (20, 72), (38, 80))
    a.shape(0x272d37, (63, 72), (69, 66), (81, 66), (89, 72), (87, 77), (63, 78))
    a.deep((63, 78), (87, 77), (88, 79), (62, 80))
    a.shape(0x677886, (69, 70), (72, 67), (80, 67), (84, 70))
    a.rect(0xc69273, 65, 73, 4, 2)
    a.rect(0xc69273, 82, 73, 4, 2)
    a.spark(65, 72.5, 4, 3)
    a.spark(82, 72.5, 4, 3)
}
