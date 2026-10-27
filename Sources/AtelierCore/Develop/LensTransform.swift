import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// Lightroom's Profile menu, Lens Corrections and Transform panels. All of it happens at the
// start of the pipeline, right after decode, so the adjustments, the masks and the crop work on
// the corrected photo.

extension DevelopSettings {
    /// The base look under every slider (Basic > Profile).
    public enum Profile: String, Codable, CaseIterable, Sendable {
        /// The camera's look, matched to the preview it embedded (see `CameraMatch`).
        case cameraMatching
        /// Apple's RAW render with no camera look.
        case appleNeutral

        public var title: String {
            switch self {
            case .cameraMatching: return "Camera Matching"
            case .appleNeutral: return "Apple Neutral"
            }
        }
    }

    /// Transform > Upright: a correction solved from the photo's lines (or the guides drawn on
    /// it), stored so it never changes on its own. The manual Transform sliders add to it.
    public struct Upright: Codable, Hashable, Sendable {
        public enum Mode: String, Codable, CaseIterable, Sendable {
            case auto, level, vertical, full, guided

            public var title: String { rawValue.capitalized }
        }

        public var mode: Mode
        /// Degrees: positive pitch widens the top, positive yaw enlarges the right side,
        /// positive roll turns clockwise.
        public var pitch = 0.0
        public var yaw = 0.0
        public var roll = 0.0
        /// Guided Upright's lines, up to four, on the photo before the Transform (0...1 from
        /// the top left).
        public var guides: [Guide] = []

        public init(mode: Mode, pitch: Double = 0, yaw: Double = 0, roll: Double = 0, guides: [Guide] = []) {
            self.mode = mode
            self.pitch = pitch
            self.yaw = yaw
            self.roll = roll
            self.guides = guides
        }

        public static let maxGuides = 4
    }

    public struct Guide: Codable, Hashable, Sendable {
        public var start: MaskPoint
        public var end: MaskPoint

        public init(start: MaskPoint, end: MaskPoint) {
            self.start = start
            self.end = end
        }
    }

    /// The settings that decide the corrected photo's shape, for caching what depends on it.
    public var lensGeometryKey: DevelopSettings {
        var key = DevelopSettings()
        key.lensProfileCorrections = lensProfileCorrections
        key.upright = upright
        key.constrainCrop = constrainCrop
        for parameter in Parameter.allCases where parameter.panel == .lensCorrections || parameter.panel == .transform {
            key[parameter] = self[parameter]
        }
        return key
    }

    /// Whether the Lens Corrections or Transform panels change the photo's shape.
    public var hasLensGeometry: Bool {
        upright != nil || self[.lensDistortion] != 0 || constrainCrop
            || Parameter.allCases.contains { $0.panel == .transform && self[$0] != $0.defaultValue }
    }
}

/// The lens distortion and perspective warp for one photo's settings, in a frame the size of
/// the photo. Points are measured from the photo's center in units of its long edge, y down.
public struct LensGeometry: Sendable {
    /// Half the frame's width and height, in long-edge units.
    public let halfWidth: Double
    public let halfHeight: Double
    /// Radial distortion: the corrected photo at radius r samples the source at r(1 + k r²/R²),
    /// R being half the diagonal.
    public let distortion: Double
    /// Corrected photo to output, including Constrain Crop's enlargement.
    public let matrix: Matrix3
    public let inverse: Matrix3

    /// `size` is the photo's (any scale); `focalLength35` its 35 mm equivalent focal length.
    public init(settings: DevelopSettings, size: CGSize, focalLength35: Double) {
        let long = max(1, Double(max(size.width, size.height)))
        halfWidth = Double(size.width) / long / 2
        halfHeight = Double(size.height) / long / 2
        distortion = -settings[.lensDistortion] / 100 * 0.2
        let upright = settings.upright
        let transform = Perspective(
            pitch: (upright?.pitch ?? 0) - settings[.transformVertical] * 0.3,
            yaw: (upright?.yaw ?? 0) + settings[.transformHorizontal] * 0.3,
            roll: (upright?.roll ?? 0) + settings[.transformRotate],
            aspect: settings[.transformAspect],
            scale: settings[.transformScale] / 100,
            offsetX: settings[.transformOffsetX] / 100 * halfWidth,
            offsetY: settings[.transformOffsetY] / 100 * halfHeight,
            focal: Self.focal(focalLength35))
        var matrix = transform.matrix
        if settings.constrainCrop {
            let grow = Self.fillScale(matrix: matrix, distortion: distortion, halfWidth: halfWidth, halfHeight: halfHeight)
            matrix = Matrix3.scale(grow, grow) * matrix
        }
        self.matrix = matrix
        inverse = matrix.inverted ?? .identity
    }

    /// Focal length in long-edge units: a full frame's long edge is 36 mm.
    public static func focal(_ focalLength35: Double) -> Double {
        (focalLength35 > 1 ? focalLength35 : 35) / 36
    }

    public var isIdentity: Bool { distortion == 0 && matrix.isNearlyIdentity }

    /// Where a corrected-photo point (0...1 from the top left) lands in the output.
    public func outputPoint(fromSource point: CGPoint) -> CGPoint {
        normalized(matrix.apply(centered(point)))
    }

    /// The corrected-photo point that lands at an output point (0...1 from the top left).
    public func sourcePoint(fromOutput point: CGPoint) -> CGPoint {
        normalized(inverse.apply(centered(point)))
    }

    private func centered(_ point: CGPoint) -> SIMD2<Double> {
        SIMD2((Double(point.x) - 0.5) * 2 * halfWidth, (Double(point.y) - 0.5) * 2 * halfHeight)
    }

    private func normalized(_ point: SIMD2<Double>) -> CGPoint {
        CGPoint(x: point.x / (2 * halfWidth) + 0.5, y: point.y / (2 * halfHeight) + 0.5)
    }

    /// The source point an output point samples, distortion included (centered units).
    func sample(_ output: SIMD2<Double>) -> SIMD2<Double> {
        let p = inverse.apply(output)
        let r2 = (p.x * p.x + p.y * p.y) / (halfWidth * halfWidth + halfHeight * halfHeight)
        return p * (1 + distortion * r2)
    }

    /// The smallest enlargement (at least 1) that keeps every output edge point on the photo.
    static func fillScale(matrix: Matrix3, distortion: Double, halfWidth: Double, halfHeight: Double) -> Double {
        guard let inverse = matrix.inverted else { return 1 }
        let diagonal2 = halfWidth * halfWidth + halfHeight * halfHeight
        var edge: [SIMD2<Double>] = []
        let steps = 12
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 - 1
            edge.append(SIMD2(t * halfWidth, -halfHeight))
            edge.append(SIMD2(t * halfWidth, halfHeight))
            edge.append(SIMD2(-halfWidth, t * halfHeight))
            edge.append(SIMD2(halfWidth, t * halfHeight))
        }
        func fits(_ scale: Double) -> Bool {
            edge.allSatisfy { point in
                var p = inverse.apply(point / scale)
                p *= 1 + distortion * (p.x * p.x + p.y * p.y) / diagonal2
                return abs(p.x) <= halfWidth * 1.0005 && abs(p.y) <= halfHeight * 1.0005
            }
        }
        if fits(1) { return 1 }
        var low = 1.0, high = 6.0
        guard fits(high) else { return high }
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if fits(mid) { high = mid } else { low = mid }
        }
        return high
    }

    // MARK: Rendering

    /// Light gray where the correction leaves the frame empty, as in Lightroom.
    static let fill = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6))

    /// The warp: output pixel to corrected-photo pixel (the inverse Transform), then through
    /// the lens distortion to the source pixel. Compiled from Metal at run time.
    private static let compiled: (kernel: CIWarpKernel?, error: String?) = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;
            [[stitchable]] float2 atelierLensWarp(float3 r0, float3 r1, float3 r2, float4 lens,
                                                  coreimage::destination dest) {
                float3 p = float3(dest.coord(), 1.0);
                float2 s = float2(dot(r0, p), dot(r1, p)) / dot(r2, p);
                float2 v = s - lens.xy;
                return lens.xy + v * (1.0 + lens.w * dot(v, v) * lens.z);
            }
            """
        do {
            let kernels = try CIKernel.kernels(withMetalString: source)
            if let warp = kernels.compactMap({ $0 as? CIWarpKernel }).first { return (warp, nil) }
            return (nil, "no warp kernel in \(kernels)")
        } catch {
            return (nil, String(describing: error))
        }
    }()

    /// Why the warp kernel could not be built, if it could not; the plain perspective is used then.
    public static var kernelError: String? { compiled.error }

    /// Warps `image` (its extent at the origin) into a frame of the same size.
    public func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        let extent = image.extent
        let width = Double(extent.width), height = Double(extent.height)
        let long = max(width, height)
        // Core Image pixels (y up) to centered long-edge units (y down), and back.
        let toCentered = Matrix3(rows: [SIMD3(1 / long, 0, -width / 2 / long),
                                        SIMD3(0, -1 / long, height / 2 / long),
                                        SIMD3(0, 0, 1)])
        let toPixels = Matrix3(rows: [SIMD3(long, 0, width / 2),
                                      SIMD3(0, -long, height / 2),
                                      SIMD3(0, 0, 1)])
        var warped: CIImage?
        if let kernel = Self.compiled.kernel {
            let m = toPixels * inverse * toCentered
            let lens = CIVector(x: width / 2, y: height / 2, z: 4 / (width * width + height * height), w: distortion)
            warped = kernel.apply(extent: extent, roiCallback: { _, _ in extent }, image: image,
                                  arguments: [m.ciRow(0), m.ciRow(1), m.ciRow(2), lens])
        }
        if warped == nil {
            // Without the kernel: the perspective alone, by moving the corners.
            let forward = toPixels * matrix * toCentered
            func corner(_ x: Double, _ y: Double) -> CGPoint {
                let p = forward.apply(SIMD2(x, y))
                return CGPoint(x: p.x, y: p.y)
            }
            let filter = CIFilter.perspectiveTransform()
            filter.inputImage = image
            filter.topLeft = corner(0, height)
            filter.topRight = corner(width, height)
            filter.bottomRight = corner(width, 0)
            filter.bottomLeft = corner(0, 0)
            warped = filter.outputImage?.cropped(to: extent)
        }
        return (warped ?? image).composited(over: Self.fill.cropped(to: extent))
    }
}

/// Lightroom's Transform as a camera turned in front of the photo: pitch and yaw tilt it,
/// then it is rotated, stretched, scaled and moved. The photo's center stays put.
struct Perspective {
    var pitch = 0.0, yaw = 0.0, roll = 0.0
    /// -100...100: positive stretches the width.
    var aspect = 0.0
    var scale = 1.0
    var offsetX = 0.0, offsetY = 0.0
    var focal = 35.0 / 36

    var matrix: Matrix3 {
        let p = pitch * .pi / 180, y = yaw * .pi / 180, r = roll * .pi / 180
        let rx = Matrix3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p))])
        let ry = Matrix3(rows: [SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))])
        let k = Matrix3.scale(focal, focal), kInverse = Matrix3.scale(1 / focal, 1 / focal)
        var h = k * ry * rx * kInverse
        // Keep the center where it was.
        let center = h.apply(SIMD2(0, 0))
        h = Matrix3.translation(-center.x, -center.y) * h
        let rotation = Matrix3(rows: [SIMD3(cos(r), -sin(r), 0), SIMD3(sin(r), cos(r), 0), SIMD3(0, 0, 1)])
        let stretch = exp(aspect / 100 * 0.25)
        return Matrix3.translation(offsetX, offsetY) * Matrix3.scale(scale * stretch, scale / stretch) * rotation * h
    }
}

/// A 3 × 3 matrix acting on homogeneous 2D points.
public struct Matrix3: Equatable, Sendable {
    public var rows: [SIMD3<Double>]

    public init(rows: [SIMD3<Double>]) { self.rows = rows }

    public static let identity = Matrix3(rows: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])

    static func scale(_ x: Double, _ y: Double) -> Matrix3 {
        Matrix3(rows: [SIMD3(x, 0, 0), SIMD3(0, y, 0), SIMD3(0, 0, 1)])
    }

    static func translation(_ x: Double, _ y: Double) -> Matrix3 {
        Matrix3(rows: [SIMD3(1, 0, x), SIMD3(0, 1, y), SIMD3(0, 0, 1)])
    }

    /// Equal to the identity but for rounding (f × 1/f is not always exactly 1).
    var isNearlyIdentity: Bool {
        zip(rows, Matrix3.identity.rows).allSatisfy { a, b in
            abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.z - b.z) < 1e-9
        }
    }

    public static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        let columns = (0..<3).map { j in SIMD3(b.rows[0][j], b.rows[1][j], b.rows[2][j]) }
        return Matrix3(rows: a.rows.map { row in
            SIMD3((row * columns[0]).sum(), (row * columns[1]).sum(), (row * columns[2]).sum())
        })
    }

    public func apply(_ point: SIMD2<Double>) -> SIMD2<Double> {
        let p = SIMD3(point.x, point.y, 1)
        let x = (rows[0] * p).sum(), y = (rows[1] * p).sum(), w = (rows[2] * p).sum()
        return SIMD2(x / w, y / w)
    }

    public var inverted: Matrix3? {
        let a = rows[0], b = rows[1], c = rows[2]
        let r0 = SIMD3(b.y * c.z - b.z * c.y, a.z * c.y - a.y * c.z, a.y * b.z - a.z * b.y)
        let r1 = SIMD3(b.z * c.x - b.x * c.z, a.x * c.z - a.z * c.x, a.z * b.x - a.x * b.z)
        let r2 = SIMD3(b.x * c.y - b.y * c.x, a.y * c.x - a.x * c.y, a.x * b.y - a.y * b.x)
        let determinant = a.x * r0.x + a.y * r1.x + a.z * r2.x
        guard abs(determinant) > 1e-12 else { return nil }
        return Matrix3(rows: [r0 / determinant, r1 / determinant, r2 / determinant])
    }

    func ciRow(_ i: Int) -> CIVector {
        CIVector(x: rows[i].x, y: rows[i].y, z: rows[i].z)
    }
}

// MARK: Upright

/// A straight edge found in a photo, 0...1 from the top left.
public struct LineSegment: Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }
}

public enum UprightSolver {
    /// Solves an Upright mode for a photo of `size` from its lines (for Guided, the guides).
    /// Returns nil when there are too few usable lines.
    public static func solve(_ mode: DevelopSettings.Upright.Mode, lines: [LineSegment], size: CGSize,
                             focalLength35: Double) -> DevelopSettings.Upright? {
        let long = max(1, Double(max(size.width, size.height)))
        let hw = Double(size.width) / long / 2, hh = Double(size.height) / long / 2
        struct Line { var a: SIMD2<Double>; var b: SIMD2<Double>; var vertical: Bool; var weight: Double }
        let guided = mode == .guided
        var usable: [Line] = []
        for line in lines {
            let a = SIMD2((Double(line.start.x) - 0.5) * 2 * hw, (Double(line.start.y) - 0.5) * 2 * hh)
            let b = SIMD2((Double(line.end.x) - 0.5) * 2 * hw, (Double(line.end.y) - 0.5) * 2 * hh)
            let d = b - a
            let length = (d * d).sum().squareRoot()
            guard length > 0.01 else { continue }
            // Angle from horizontal, 0...90°.
            let angle = atan2(abs(d.y), abs(d.x)) * 180 / .pi
            if guided {
                usable.append(Line(a: a, b: b, vertical: angle > 45, weight: 1))
            } else if angle <= 30 {
                usable.append(Line(a: a, b: b, vertical: false, weight: length))
            } else if angle >= 60 {
                usable.append(Line(a: a, b: b, vertical: true, weight: length))
            }
        }
        let verticals = usable.filter(\.vertical).count, horizontals = usable.count - verticals
        guard !usable.isEmpty, guided || usable.count >= 2 else { return nil }
        var free: [Int] = [2]  // roll
        switch mode {
        case .level:
            break
        case .vertical:
            if verticals >= 2 { free.append(0) }
        case .auto, .full, .guided:
            if verticals >= 2 { free.append(0) }
            if horizontals >= 2 { free.append(1) }
        }
        if mode == .vertical, !free.contains(0) { return nil }
        let regularization = mode == .auto ? 0.08 : 0.0002
        let limits = mode == .auto ? [20.0, 20.0, 15.0] : [50.0, 50.0, 45.0]
        let focal = LensGeometry.focal(focalLength35)

        func cost(_ params: [Double], _ lines: [Line]) -> Double {
            let m = Perspective(pitch: params[0], yaw: params[1], roll: params[2], focal: focal).matrix
            let total = lines.reduce(0) { $0 + $1.weight }
            var sum = 0.0
            for line in lines {
                let d = m.apply(line.b) - m.apply(line.a)
                let length2 = (d * d).sum()
                guard length2 > 1e-12 else { sum += line.weight; continue }
                let off = line.vertical ? d.x : d.y
                sum += line.weight * off * off / length2
            }
            let r = params.map { $0 * .pi / 180 }
            return sum / max(total, 1e-9) + regularization * (r[0] * r[0] + r[1] * r[1] + r[2] * r[2])
        }

        func descend(_ lines: [Line]) -> [Double] {
            var params = [0.0, 0.0, 0.0]
            var best = cost(params, lines)
            var step = 4.0
            var iterations = 0
            while step > 0.005, iterations < 4000 {
                iterations += 1
                var improved = false
                for i in free {
                    for direction in [1.0, -1.0] {
                        var candidate = params
                        candidate[i] = min(limits[i], max(-limits[i], candidate[i] + direction * step))
                        let c = cost(candidate, lines)
                        if c < best {
                            best = c
                            params = candidate
                            improved = true
                            break
                        }
                    }
                }
                if !improved { step /= 2 }
            }
            return params
        }

        var params = descend(usable)
        if !guided {
            // Drop lines that still lean more than 5° (trees, diagonals), then solve again.
            let m = Perspective(pitch: params[0], yaw: params[1], roll: params[2], focal: focal).matrix
            let kept = usable.filter { line in
                let d = m.apply(line.b) - m.apply(line.a)
                let off = abs(line.vertical ? d.x : d.y) / max(1e-9, (d * d).sum().squareRoot())
                return off < sin(5 * .pi / 180)
            }
            if kept.count >= 2, kept.count < usable.count { params = descend(kept) }
        }
        return DevelopSettings.Upright(mode: mode, pitch: params[0], yaw: params[1], roll: params[2])
    }
}

/// Finds straight edges in a grayscale image, LSD-style: pixels with a strong gradient are
/// grown into regions of the same edge direction, and thin, long regions become segments.
public enum LineDetector {
    /// `pixels` holds `width × height` brightness values 0...1, first row at the top.
    public static func detect(_ pixels: [Float], width: Int, height: Int) -> [LineSegment] {
        guard width > 4, height > 4, pixels.count >= width * height else { return [] }
        // Light blur, then Sobel.
        var blurred = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0, weight: Float = 0
                for dy in -1...1 {
                    let yy = min(height - 1, max(0, y + dy))
                    for dx in -1...1 {
                        let xx = min(width - 1, max(0, x + dx))
                        let w: Float = (dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1)
                        sum += pixels[yy * width + xx] * w
                        weight += w
                    }
                }
                blurred[y * width + x] = sum / weight
            }
        }
        var magnitude = [Float](repeating: 0, count: width * height)
        var angle = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                func p(_ dx: Int, _ dy: Int) -> Float { blurred[(y + dy) * width + x + dx] }
                let gx = (p(1, -1) + 2 * p(1, 0) + p(1, 1) - p(-1, -1) - 2 * p(-1, 0) - p(-1, 1)) / 4
                let gy = (p(-1, 1) + 2 * p(0, 1) + p(1, 1) - p(-1, -1) - 2 * p(0, -1) - p(1, -1)) / 4
                magnitude[y * width + x] = (gx * gx + gy * gy).squareRoot()
                angle[y * width + x] = atan2(gy, gx)
            }
        }
        let threshold: Float = 0.04
        let seeds = (0..<(width * height)).filter { magnitude[$0] > threshold }
            .sorted { magnitude[$0] > magnitude[$1] }
        var used = [Bool](repeating: false, count: width * height)
        let long = Double(max(width, height))
        let tolerance = Float(22.5 * Double.pi / 180)
        var segments: [LineSegment] = []
        var region: [Int] = []
        for seed in seeds where !used[seed] {
            used[seed] = true
            region.removeAll(keepingCapacity: true)
            region.append(seed)
            // Doubled angles, so an edge that flips from light-dark to dark-light still matches.
            var sumCos = cos(2 * angle[seed]), sumSin = sin(2 * angle[seed])
            var index = 0
            while index < region.count {
                let current = region[index]
                index += 1
                let cx = current % width, cy = current / width
                let mean = atan2(sumSin, sumCos) / 2
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let n = ny * width + nx
                        guard !used[n], magnitude[n] > threshold else { continue }
                        var diff = abs(angle[n] - mean).truncatingRemainder(dividingBy: .pi)
                        if diff > .pi / 2 { diff = .pi - diff }
                        guard diff < tolerance else { continue }
                        used[n] = true
                        region.append(n)
                        sumCos += cos(2 * angle[n])
                        sumSin += sin(2 * angle[n])
                    }
                }
            }
            guard Double(region.count) >= max(12, long * 0.03) else { continue }
            if let segment = fit(region, width: width, height: height, long: long) { segments.append(segment) }
        }
        return segments
    }

    /// The region's principal axis, if the region is long and thin enough to be a line.
    private static func fit(_ region: [Int], width: Int, height: Int, long: Double) -> LineSegment? {
        let count = Double(region.count)
        var mx = 0.0, my = 0.0
        for i in region {
            mx += Double(i % width)
            my += Double(i / width)
        }
        mx /= count
        my /= count
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in region {
            let dx = Double(i % width) - mx, dy = Double(i / width) - my
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        sxx /= count
        syy /= count
        sxy /= count
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let ux = cos(theta), uy = sin(theta)
        var tMin = Double.infinity, tMax = -Double.infinity, minor = 0.0
        for i in region {
            let dx = Double(i % width) - mx, dy = Double(i / width) - my
            let t = dx * ux + dy * uy
            tMin = min(tMin, t)
            tMax = max(tMax, t)
            let s = -dx * uy + dy * ux
            minor += s * s
        }
        let length = tMax - tMin
        let thickness = 4 * (minor / count).squareRoot() + 1
        guard length >= long * 0.04, length / thickness >= 6 else { return nil }
        // Pixel centers, as fractions of the image.
        func point(_ t: Double) -> CGPoint {
            CGPoint(x: (mx + ux * t + 0.5) / Double(width), y: (my + uy * t + 0.5) / Double(height))
        }
        return LineSegment(start: point(tMin), end: point(tMax))
    }
}
