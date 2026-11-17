import CoreImage
import Foundation

/// How a camera's RAW engine changes a photo when Temp and Tint move (AT-079d), so a smart
/// preview, which has no camera data, can follow the original exactly. For a grid of whites, the
/// 3×3 that takes the camera's render at a 5000 K reference to its render at that white, in the
/// working space of the context that renders it (`DevelopRenderer.workingSpace`, extended linear
/// Rec. 2020: `CIRAWFilter.linearSpaceFilter` sees the rendering context's working space, so a
/// table fitted in another space puts red off by up to 28/255; the Mac check of Nov 17). A
/// change from the as-shot white to any other is then `matrix(to) · matrix(as shot)⁻¹`.
///
/// Fitted once per camera model from its first photo (least squares over the unclipped pixels of
/// two small linear renders; the spike found a D3100's table from one photo matched another's
/// within 0.1/255), and kept beside the smart previews.
public struct CameraWhite: Codable, Hashable, Sendable {
    public var version = 1
    public var camera: String
    /// The colour space the matrices work in; a table in another space than the renderer's is
    /// fitted again.
    public var space: String
    /// Grid temperatures in Kelvin, warm to cool (evenly spaced in mired).
    public var temperatures: [Double]
    /// Grid tints, Apple's scale (as `CIRAWFilter.neutralTint`).
    public var tints: [Double]
    /// Row-major 3×3s, `tints.count` per temperature, temperature-major.
    public var matrices: [[Double]]

    public static let reference = (temperature: 5000.0, tint: 0.0)
    /// The renderer's working space by name, as `space` records it.
    public static var currentSpace: String { (DevelopRenderer.workingSpace.name as String?) ?? "" }
    /// Whether this table works in the renderer's current space.
    public var isCurrent: Bool { space == Self.currentSpace }
    /// 2000–50000 K (Develop's range) in 18 mired steps, 9 tints across −150…150.
    public static let gridTemperatures: [Double] = {
        let warm = 1e6 / 2000, cool = 1e6 / 50000
        return (0..<18).map { 1e6 / (warm + (cool - warm) * Double($0) / 17) }
    }()
    public static let gridTints: [Double] = [-150, -100, -60, -30, 0, 30, 60, 100, 150]

    /// The change from the as-shot white to (temperature, tint): identity when they are the same.
    public func change(from shot: (temperature: Double, tint: Double), to temperature: Double, tint: Double) -> [Double] {
        if abs(shot.temperature - temperature) < 0.5, abs(shot.tint - tint) < 0.01 { return WhiteMatrix3.identity }
        let back = WhiteMatrix3.inverse(matrix(temperature: shot.temperature, tint: shot.tint)) ?? WhiteMatrix3.identity
        return WhiteMatrix3.multiply(matrix(temperature: temperature, tint: tint), back)
    }

    /// The grid's matrix at (temperature, tint), bilinear in mired and tint, clamped to the grid.
    public func matrix(temperature: Double, tint: Double) -> [Double] {
        let mireds = temperatures.map { 1e6 / $0 }
        let (t0, t1, ft) = Self.bracket(1e6 / max(1, temperature), in: mireds)
        let (n0, n1, fn) = Self.bracket(tint, in: tints)
        let width = tints.count
        func at(_ t: Int, _ n: Int) -> [Double] { matrices[t * width + n] }
        return (0..<9).map { k in
            let top = at(t0, n0)[k] * (1 - fn) + at(t0, n1)[k] * fn
            let bottom = at(t1, n0)[k] * (1 - fn) + at(t1, n1)[k] * fn
            return top * (1 - ft) + bottom * ft
        }
    }

    /// The two grid indices around `value` and how far between them it is (0…1).
    static func bracket(_ value: Double, in grid: [Double]) -> (Int, Int, Double) {
        guard grid.count > 1 else { return (0, 0, 0) }
        let ascending = grid.first! < grid.last!
        for i in 0..<(grid.count - 1) {
            let a = grid[i], b = grid[i + 1]
            let inside = ascending ? (value >= a && value <= b) : (value <= a && value >= b)
            if inside { return (i, i + 1, b == a ? 0 : (value - a) / (b - a)) }
        }
        let beforeFirst = ascending ? value < grid.first! : value > grid.first!
        return beforeFirst ? (0, 0, 0) : (grid.count - 1, grid.count - 1, 0)
    }

    // MARK: Fitting

    /// Fits the table from one RAW of the camera. About 160 small renders; run it in the background.
    public static func fit(from raw: URL, camera: String, context: CIContext,
                           shouldStop: () -> Bool = { false }) -> CameraWhite? {
        // One filter for every render: it keeps the decoded sensor data between white changes.
        guard let filter = fittingFilter(raw),
              let base = linearPixels(filter, temperature: Self.reference.temperature, tint: Self.reference.tint, context: context) else { return nil }
        var matrices: [[Double]] = []
        for temperature in gridTemperatures {
            for tint in gridTints {
                if shouldStop() { return nil }
                guard let target = linearPixels(filter, temperature: temperature, tint: tint, context: context),
                      let matrix = leastSquares(from: base, to: target) else { return nil }
                matrices.append(matrix)
            }
        }
        return CameraWhite(camera: camera, space: currentSpace, temperatures: gridTemperatures, tints: gridTints, matrices: matrices)
    }

    /// Long edge of the fitting renders: enough pixels for a 3×3, fast to decode.
    static let fitEdge: CGFloat = 256

    /// Small, linear (no tone curve, boosts or gamut mapping): a change of white is then a 3×3.
    static func fittingFilter(_ url: URL) -> CIRAWFilter? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = max(filter.nativeSize.width, filter.nativeSize.height)
        if native > fitEdge { filter.scaleFactor = Float(fitEdge / native) }
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.isGamutMappingEnabled = false
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        return filter
    }

    static func linearPixels(_ filter: CIRAWFilter, temperature: Double, tint: Double, context: CIContext) -> [Float]? {
        filter.neutralTemperature = Float(temperature)
        filter.neutralTint = Float(tint)
        guard let image = filter.outputImage else { return nil }
        let space = DevelopRenderer.workingSpace
        let extent = image.extent.integral
        var pixels = [Float](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: Int(extent.width) * 16, bounds: extent,
                           format: .RGBAf, colorSpace: space)
        }
        return pixels
    }

    /// The 3×3 A minimising |A x − y| over pixels unclipped in both: A = YXᵀ (XXᵀ)⁻¹.
    static func leastSquares(from a: [Float], to b: [Float]) -> [Double]? {
        guard a.count == b.count else { return nil }
        var xx = [Double](repeating: 0, count: 9), yx = [Double](repeating: 0, count: 9)
        var used = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let x0 = Double(a[i]), x1 = Double(a[i + 1]), x2 = Double(a[i + 2])
            let y0 = Double(b[i]), y1 = Double(b[i + 1]), y2 = Double(b[i + 2])
            let ok = { (v: Double) in v > 0.002 && v < 0.9 }
            // The target is only checked for being a number: at the warm end of the grid
            // (2000–2250 K) red, and green with a magenta tint, are negative for every pixel in
            // extended linear sRGB (out of gamut, gamut mapping off) yet still a linear change.
            // The target may go negative (warm whites push red below zero, unclamped); only its
            // highlights, where the engine's recovery isn't linear, are left out.
            let fine = { (v: Double) in v.isFinite && v < 0.9 }
            guard ok(x0), ok(x1), ok(x2), fine(y0), fine(y1), fine(y2) else { continue }
            let x = [x0, x1, x2], y = [y0, y1, y2]
            for r in 0..<3 {
                for c in 0..<3 {
                    xx[r * 3 + c] += x[r] * x[c]
                    yx[r * 3 + c] += y[r] * x[c]
                }
            }
            used += 1
        }
        guard used >= 64, let inverse = WhiteMatrix3.inverse(xx) else { return nil }
        return WhiteMatrix3.multiply(yx, inverse)
    }
}

/// Row-major 3×3 helpers, written out so the type checker finishes.
public enum WhiteMatrix3 {
    public static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    public static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum = 0.0
                for j in 0..<3 { sum += a[row * 3 + j] * b[j * 3 + column] }
                out[row * 3 + column] = sum
            }
        }
        return out
    }

    public static func inverse(_ m: [Double]) -> [Double]? {
        let c00: Double = m[4] * m[8] - m[5] * m[7]
        let c01: Double = m[2] * m[7] - m[1] * m[8]
        let c02: Double = m[1] * m[5] - m[2] * m[4]
        let c10: Double = m[5] * m[6] - m[3] * m[8]
        let c11: Double = m[0] * m[8] - m[2] * m[6]
        let c12: Double = m[2] * m[3] - m[0] * m[5]
        let c20: Double = m[3] * m[7] - m[4] * m[6]
        let c21: Double = m[1] * m[6] - m[0] * m[7]
        let c22: Double = m[0] * m[4] - m[1] * m[3]
        let det: Double = m[0] * c00 + m[1] * c10 + m[2] * c20
        guard abs(det) > 1e-12 else { return nil }
        return [c00, c01, c02, c10, c11, c12, c20, c21, c22].map { $0 / det }
    }

    /// A CIColorMatrix applying `m` to RGB.
    public static func filter(_ m: [Double]) -> CIFilter {
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(CIVector(x: m[0], y: m[1], z: m[2], w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: m[3], y: m[4], z: m[5], w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: m[6], y: m[7], z: m[8], w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return filter
    }
}
