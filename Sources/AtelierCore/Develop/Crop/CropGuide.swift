import CoreGraphics
import Foundation

/// The composition guides drawn inside the crop frame, as Lightroom Classic's Tools > Crop Guide
/// Overlay lists them. O cycles them in the crop tool and ⇧O turns the ones with a direction
/// (Triangle, Golden Spiral) to the next orientation.
public enum CropGuide: String, CaseIterable, Codable, Sendable {
    case grid, thirds, diagonal, triangle, goldenRatio, goldenSpiral, aspectRatios

    public var title: String {
        switch self {
        case .grid: return "Grid"
        case .thirds: return "Thirds"
        case .diagonal: return "Diagonal"
        case .triangle: return "Triangle"
        case .goldenRatio: return "Golden Ratio"
        case .goldenSpiral: return "Golden Spiral"
        case .aspectRatios: return "Aspect Ratios"
        }
    }

    /// How many ways ⇧O can turn it: the spiral's eye can sit in any corner, winding either way;
    /// the triangle's long diagonal can run either way. The others look the same every way round.
    public var orientationCount: Int {
        switch self {
        case .goldenSpiral: return 8
        case .triangle: return 2
        default: return 1
        }
    }

    /// The next guide for O, wrapping around.
    public var next: CropGuide {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The guide's lines inside a frame of `aspect` (width / height, on screen), as polylines in
    /// 0...1 frame coordinates from the top left. Curves are flattened into short segments, so a
    /// view only maps the points into its rectangle. `orientation` is taken modulo
    /// `orientationCount`.
    public func polylines(aspect: Double, orientation: Int = 0) -> [[CGPoint]] {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        let turn = ((orientation % orientationCount) + orientationCount) % orientationCount
        switch self {
        case .grid: return Self.grid(aspect: aspect, cellsOnShortSide: 6)
        case .thirds: return Self.divisions(at: [1.0 / 3, 2.0 / 3])
        case .goldenRatio: return Self.divisions(at: [1 - 1 / Self.phi, 1 / Self.phi])
        case .diagonal: return Self.diagonals(aspect: aspect)
        case .triangle: return Self.triangle(aspect: aspect, mirrored: turn == 1)
        case .goldenSpiral: return Self.spiral().map { $0.map { Self.oriented($0, turn) } }
        case .aspectRatios: return Self.aspectRatioFrames(aspect: aspect)
        }
    }

    /// The fine grid shown while straightening, whichever guide is chosen (as in Lightroom).
    public static func straightenGrid(aspect: Double) -> [[CGPoint]] {
        grid(aspect: aspect.isFinite && aspect > 0 ? aspect : 1, cellsOnShortSide: 8)
    }

    static let phi = (1 + 5.0.squareRoot()) / 2

    /// The ratios the Aspect Ratios guide outlines, landscape width / height (Lightroom's list).
    public static let outlinedRatios: [Double] = [1, 5.0 / 4, 7.0 / 5, 3.0 / 2, 4.0 / 3, 16.0 / 10, 16.0 / 9]

    // MARK: Shapes

    /// Vertical and horizontal lines at the same fractions of the width and height.
    private static func divisions(at fractions: [Double]) -> [[CGPoint]] {
        fractions.flatMap { f in
            [[CGPoint(x: f, y: 0), CGPoint(x: f, y: 1)], [CGPoint(x: 0, y: f), CGPoint(x: 1, y: f)]]
        }
    }

    /// Square cells, `cellsOnShortSide` across the shorter side, starting at the top left.
    private static func grid(aspect: Double, cellsOnShortSide: Int) -> [[CGPoint]] {
        let width = aspect, height = 1.0
        let cell = min(width, height) / Double(cellsOnShortSide)
        var lines: [[CGPoint]] = []
        var x = cell
        while x < width - cell * 0.01 {
            lines.append([CGPoint(x: x / width, y: 0), CGPoint(x: x / width, y: 1)])
            x += cell
        }
        var y = cell
        while y < height - cell * 0.01 {
            lines.append([CGPoint(x: 0, y: y), CGPoint(x: 1, y: y)])
            y += cell
        }
        return lines
    }

    /// Lightroom's Diagonal: a 45° line in from each corner until it meets the far side.
    private static func diagonals(aspect: Double) -> [[CGPoint]] {
        let w = aspect, h = 1.0, side = min(w, h)
        let lines: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: 0), CGPoint(x: side, y: side)),
            (CGPoint(x: 0, y: h), CGPoint(x: side, y: h - side)),
            (CGPoint(x: w, y: 0), CGPoint(x: w - side, y: side)),
            (CGPoint(x: w, y: h), CGPoint(x: w - side, y: h - side)),
        ]
        return lines.map { [normalized($0.0, w), normalized($0.1, w)] }
    }

    /// One corner-to-corner diagonal and the perpendiculars to it from the other two corners.
    private static func triangle(aspect: Double, mirrored: Bool) -> [[CGPoint]] {
        let w = aspect, h = 1.0
        let a = mirrored ? CGPoint(x: w, y: 0) : CGPoint(x: 0, y: 0)
        let b = mirrored ? CGPoint(x: 0, y: h) : CGPoint(x: w, y: h)
        let others = mirrored ? [CGPoint(x: 0, y: 0), CGPoint(x: w, y: h)] : [CGPoint(x: w, y: 0), CGPoint(x: 0, y: h)]
        var lines = [[normalized(a, w), normalized(b, w)]]
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        for corner in others {
            let t = ((corner.x - a.x) * dx + (corner.y - a.y) * dy) / length2
            let foot = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            lines.append([normalized(corner, w), normalized(foot, w)])
        }
        return lines
    }

    /// The frame cut again and again at the golden ratio, a quarter curve through each piece cut
    /// off, so the curve winds into the eye (in orientation 0, toward the lower right of center).
    /// On a frame that isn't golden the pieces are rectangles and the curves stretch with them,
    /// as Lightroom draws it.
    private static func spiral() -> [[CGPoint]] {
        var x0 = 0.0, y0 = 0.0, x1 = 1.0, y1 = 1.0
        var curve: [CGPoint] = []
        var cuts: [[CGPoint]] = []
        let steps = 10, segments = 16
        for step in 0..<steps {
            let side = step % 4
            let center: CGPoint, rx: Double, ry: Double
            switch side {
            case 0:  // cut the left piece off
                let cut = x0 + (x1 - x0) / phi
                center = CGPoint(x: cut, y: y1); rx = cut - x0; ry = y1 - y0
                cuts.append([CGPoint(x: cut, y: y0), CGPoint(x: cut, y: y1)])
                x0 = cut
            case 1:  // the top piece
                let cut = y0 + (y1 - y0) / phi
                center = CGPoint(x: x0, y: cut); rx = x1 - x0; ry = cut - y0
                cuts.append([CGPoint(x: x0, y: cut), CGPoint(x: x1, y: cut)])
                y0 = cut
            case 2:  // the right piece
                let cut = x1 - (x1 - x0) / phi
                center = CGPoint(x: cut, y: y0); rx = x1 - cut; ry = y1 - y0
                cuts.append([CGPoint(x: cut, y: y0), CGPoint(x: cut, y: y1)])
                x1 = cut
            default:  // the bottom piece
                let cut = y1 - (y1 - y0) / phi
                center = CGPoint(x: x1, y: cut); rx = x1 - x0; ry = y1 - cut
                cuts.append([CGPoint(x: x0, y: cut), CGPoint(x: x1, y: cut)])
                y1 = cut
            }
            // A quarter of the ellipse around `center`, from where the last one ended.
            let start = Double.pi + Double(side) * .pi / 2
            for i in (step == 0 ? 0 : 1)...segments {
                let t = start + Double(i) / Double(segments) * .pi / 2
                curve.append(CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t)))
            }
        }
        return [curve] + cuts
    }

    /// Centered outlines of each ratio in `outlinedRatios`, in the frame's own orientation.
    private static func aspectRatioFrames(aspect: Double) -> [[CGPoint]] {
        let w = aspect, h = 1.0
        return outlinedRatios.compactMap { ratio in
            let r = w >= h ? ratio : 1 / ratio
            let width = min(w, h * r), height = width / r
            // The frame's own shape draws nothing new.
            guard abs(width - w) > 1e-3 || abs(height - h) > 1e-3 else { return nil }
            let left = (w - width) / 2, top = (h - height) / 2
            let corners = [CGPoint(x: left, y: top), CGPoint(x: left + width, y: top),
                           CGPoint(x: left + width, y: top + height), CGPoint(x: left, y: top + height),
                           CGPoint(x: left, y: top)]
            return corners.map { normalized($0, w) }
        }
    }

    // MARK: Helpers

    private static func normalized(_ point: CGPoint, _ width: Double) -> CGPoint {
        CGPoint(x: point.x / width, y: point.y)
    }

    /// Orientation 0...7: bit 0 mirrors left to right, bit 1 top to bottom, bit 2 swaps the axes
    /// first (so the spiral winds the other way). All eight keep the shape in the frame.
    private static func oriented(_ point: CGPoint, _ orientation: Int) -> CGPoint {
        var p = orientation & 4 != 0 ? CGPoint(x: point.y, y: point.x) : point
        if orientation & 1 != 0 { p.x = 1 - p.x }
        if orientation & 2 != 0 { p.y = 1 - p.y }
        return p
    }
}

/// When the crop tool draws its guide (Lightroom's Tools > Tool Overlay).
public enum CropGuideVisibility: String, CaseIterable, Codable, Sendable {
    case always, whileDragging, never

    public var title: String {
        switch self {
        case .always: return "Always"
        case .whileDragging: return "While Dragging"
        case .never: return "Never"
        }
    }
}

public extension DevelopSettings.Crop {
    /// The part of the crop the crop tool's render depends on. The tool shows the whole photo,
    /// upright, and turns and frames it in the view, so only quarter turns and flips change the
    /// pixels; a drag of the frame or the angle needs no new render.
    var cropToolView: DevelopSettings.Crop {
        var view = DevelopSettings.Crop()
        view.quarterTurns = quarterTurns
        view.flipHorizontal = flipHorizontal
        view.flipVertical = flipVertical
        return view
    }
}
