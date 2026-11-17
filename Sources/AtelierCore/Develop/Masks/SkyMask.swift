import Foundation

/// Select Sky (AT-068) from the depth model's output and the photo's colors on the same grid.
///
/// The rules follow what the sky is rather than cut-offs tuned to one sky, so a blue noon, a
/// sunset and a night sky are found the same way (Rosh, Nov 15, 2026: "a logical fix, not a
/// bandaid that would break another sky"). Checked with the real model on Rosh's Eiffel Tower
/// NEF, two harbor panoramas, a castle with clouds and birds, a hotel with sky behind a tree, a
/// viaduct, and photos without sky (a stadium, a cathedral, a photographed map).
/// 0. **At infinity.** Depth Anything puts the sky at zero disparity (it is trained that way), so
///    "far" is measured against the photo's nearest things (`nearness`, 0 at infinity), not as the
///    farthest part of this photo: a stadium crowd or a wall is never at infinity, however far it
///    is the farthest thing shown. Fully at infinity up to `infinity.full`, fading out by
///    `infinity.none`; water reflecting the sky is near, so it never counts.
/// 1. **Open sky.** The sky has no edges: grow from the top row through pixels at infinity whose
///    color steps from their neighbor by less than `step` (a barely visible Oklab difference
///    beyond the photo's own noise). A gradient (sunset pink into blue) is many small steps and is
///    followed; a skyline or a tree line is one big step and stops it.
/// 2. **Islands.** A far region the open sky surrounds on every side (a crisp cloud, the sun, the
///    moon) is sky too. One that touches something near or the bottom of the photo isn't.
/// 3. **Seen through.** Any other far pixel is sky when its color is the open sky's color around
///    it (`LocalColor`), within `step` plus how much that sky varies there: sky behind a lattice
///    or between branches comes in, a far white building doesn't.
/// 4. **Grown on.** The sky continues from every sky pixel found in step 3 (whose neighborhood is
///    sky colored too), through pixels at infinity with no edge, so a patch of sky reached in
///    step 3 brings in the rest of its patch (sky behind a tree's branches).
/// Noise: edges are judged on colors cleaned with a 3 × 3 median (it removes noise but keeps
/// edges; the other steps use the photo's own colors), and `step` is `edgeStep` plus twice the
/// photo's median difference between neighbors at infinity.
extension DepthMap.Field {
    static let infinity: (full: Float, none: Float) = (0.01, 0.06)
    static let edgeStep: Float = 0.03

    /// Each pixel's disparity as a share of the photo's nearest (99th percentile): 0 at infinity,
    /// 1 as near as the nearest things. Without the model's output, from `values` (1 farthest).
    func nearness() -> [Float] {
        guard disparity.count == values.count else { return values.map { 1 - $0 } }
        let finite = disparity.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return values.map { 1 - $0 } }
        let nearest = max(finite[finite.count - 1 - finite.count / 100], 1e-6)
        return disparity.map { value -> Float in value.isFinite ? max(0, value) / nearest : 1 }
    }

    /// Select Sky's mask, 0...1, on the field's grid; all zero when no sky reaches the top.
    public var sky: [Float] {
        let count = width * height
        guard values.count == count else { return [] }
        let gate = Self.infinity
        let far: [Float] = nearness().map { r -> Float in Self.smooth((gate.none - r) / (gate.none - gate.full)) }
        let atInfinity: [Bool] = far.map { $0 >= 1 }
        let labs: [SIMD3<Float>]?
        if colors.count == count * 4 {
            labs = (0..<count).map { i -> SIMD3<Float> in
                Self.oklab(red: colors[i * 4], green: colors[i * 4 + 1], blue: colors[i * 4 + 2])
            }
        } else {
            labs = nil
        }
        // Edges are judged on noise-cleaned colors; the rest compares the photo's own colors.
        let cleaned = labs.map { Self.median3($0, width: width, height: height) }
        let step = cleaned.map { stepLimit(labs: $0, atInfinity: atInfinity) } ?? Self.edgeStep
        let topRow = (0..<width).filter { atInfinity[$0] }
        var open = grow(from: topRow, through: atInfinity, labs: cleaned, step: step,
                        reached: [Bool](repeating: false, count: count))
        guard open.contains(true) else { return [Float](repeating: 0, count: count) }
        // Without the photo's colors, what is at infinity and open to the top is all there is.
        guard let labs, let cleaned else { return (0..<count).map { i -> Float in open[i] ? far[i] : 0 } }
        markIslands(&open, far: far)
        let local = LocalColor(width: width, height: height, labs: labs, mask: open)
        var out = [Float](repeating: 0, count: count)
        var seeds: [Int] = []
        for i in 0..<count {
            if open[i] {
                out[i] = far[i]
                continue
            }
            guard far[i] > 0, let around = local.at(row: i / width, column: i % width) else { continue }
            let reach = step + around.spread
            let d: SIMD3<Float> = labs[i] - around.mean
            let distance: Float = (d * d).sum().squareRoot()
            out[i] = far[i] * Self.smooth((reach - distance) / (0.5 * reach))
            // A seed must be sky by its neighborhood's (cleaned) color too: at an edge the cleaned
            // color mixes both sides and would carry the sky across it.
            let dc: SIMD3<Float> = cleaned[i] - around.mean
            if out[i] > 0.5, (dc * dc).sum().squareRoot() < reach { seeds.append(i) }
        }
        var found = open
        for i in 0..<count where out[i] > 0.5 { found[i] = true }
        let grown = grow(from: seeds, through: atInfinity, labs: cleaned, step: step, reached: found)
        for i in 0..<count where grown[i] && !found[i] { out[i] = far[i] }
        return out
    }

    private func neighbors(of index: Int) -> [Int] {
        let row = index / width, column = index % width
        var result: [Int] = []
        if row > 0 { result.append(index - width) }
        if row < height - 1 { result.append(index + width) }
        if column > 0 { result.append(index - 1) }
        if column < width - 1 { result.append(index + 1) }
        return result
    }

    /// The largest color step between neighbors that isn't an edge: `edgeStep` plus twice the
    /// median step between neighbors at infinity (the photo's noise; edges are too few to move a
    /// median).
    func stepLimit(labs: [SIMD3<Float>], atInfinity: [Bool]) -> Float {
        var steps: [Float] = []
        steps.reserveCapacity(values.count * 2)
        for index in values.indices where atInfinity[index] {
            if index % width < width - 1, atInfinity[index + 1] {
                let d: SIMD3<Float> = labs[index + 1] - labs[index]
                steps.append((d * d).sum().squareRoot())
            }
            if index + width < values.count, atInfinity[index + width] {
                let d: SIMD3<Float> = labs[index + width] - labs[index]
                steps.append((d * d).sum().squareRoot())
            }
        }
        guard !steps.isEmpty else { return Self.edgeStep }
        steps.sort()
        return Self.edgeStep + 2 * steps[steps.count / 2]
    }

    /// `reached` plus every pixel in `allowed` reached from `starts` with no color step of
    /// `step` or more on the way (`labs` nil: by `allowed` alone). `starts` count as reached.
    func grow(from starts: [Int], through allowed: [Bool], labs: [SIMD3<Float>]?, step: Float,
              reached: [Bool]) -> [Bool] {
        var reached = reached
        var stack = starts
        for index in starts { reached[index] = true }
        while let index = stack.popLast() {
            for next in neighbors(of: index) where !reached[next] && allowed[next] {
                if let labs {
                    let d: SIMD3<Float> = labs[next] - labs[index]
                    guard (d * d).sum().squareRoot() < step else { continue }
                }
                reached[next] = true
                stack.append(next)
            }
        }
        return reached
    }

    /// Step 2: adds each far region that the open sky surrounds on every side (the top and the
    /// sides of the photo count as sky; the bottom doesn't).
    func markIslands(_ open: inout [Bool], far: [Float]) {
        var seen = [Bool](repeating: false, count: values.count)
        for start in values.indices where !seen[start] && !open[start] && far[start] > 0 {
            var region = [start]
            seen[start] = true
            var island = true
            var next = 0
            while next < region.count {
                let index = region[next]
                next += 1
                if index / width == height - 1 { island = false }
                for neighbor in neighbors(of: index) where !open[neighbor] {
                    if far[neighbor] <= 0 {
                        island = false
                    } else if !seen[neighbor] {
                        seen[neighbor] = true
                        region.append(neighbor)
                    }
                }
            }
            if island { for index in region { open[index] = true } }
        }
    }

    /// Each channel's median over the 3 × 3 pixels around each pixel (fewer at the photo's edges).
    static func median3(_ labs: [SIMD3<Float>], width: Int, height: Int) -> [SIMD3<Float>] {
        var out = labs
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        xs.reserveCapacity(9)
        ys.reserveCapacity(9)
        zs.reserveCapacity(9)
        for row in 0..<height {
            for column in 0..<width {
                xs.removeAll(keepingCapacity: true)
                ys.removeAll(keepingCapacity: true)
                zs.removeAll(keepingCapacity: true)
                for r in max(0, row - 1)...min(height - 1, row + 1) {
                    for c in max(0, column - 1)...min(width - 1, column + 1) {
                        let lab = labs[r * width + c]
                        xs.append(lab.x)
                        ys.append(lab.y)
                        zs.append(lab.z)
                    }
                }
                xs.sort()
                ys.sort()
                zs.sort()
                out[row * width + column] = SIMD3<Float>(xs[xs.count / 2], ys[ys.count / 2], zs[zs.count / 2])
            }
        }
        return out
    }

    /// The mean color of the masked pixels around a point, and how much they vary, from summed-area
    /// tables: a window a tenth of the height across, doubled until it holds a few masked pixels.
    struct LocalColor {
        let width: Int, height: Int
        private var counts: [Double], sums: [SIMD3<Double>], squares: [Double]

        init(width: Int, height: Int, labs: [SIMD3<Float>], mask: [Bool]) {
            self.width = width
            self.height = height
            let size = (width + 1) * (height + 1)
            counts = [Double](repeating: 0, count: size)
            sums = [SIMD3<Double>](repeating: .zero, count: size)
            squares = [Double](repeating: 0, count: size)
            for row in 0..<height {
                var count = 0.0, sum = SIMD3<Double>.zero, square = 0.0
                for column in 0..<width {
                    let i = row * width + column
                    if mask[i] {
                        let lab = SIMD3<Double>(Double(labs[i].x), Double(labs[i].y), Double(labs[i].z))
                        let labSquare: Double = (lab * lab).sum()
                        count += 1
                        sum += lab
                        square += labSquare
                    }
                    let here = (row + 1) * (width + 1) + column + 1, above = row * (width + 1) + column + 1
                    counts[here] = counts[above] + count
                    sums[here] = sums[above] + sum
                    squares[here] = squares[above] + square
                }
            }
        }

        private func corners(_ top: Int, _ left: Int, _ bottom: Int, _ right: Int) -> (Int, Int, Int, Int) {
            let stride = width + 1
            return (bottom * stride + right, top * stride + right, bottom * stride + left, top * stride + left)
        }

        private func box(_ table: [Double], _ c: (Int, Int, Int, Int)) -> Double {
            let positive = table[c.0] + table[c.3]
            let negative = table[c.1] + table[c.2]
            return positive - negative
        }

        private func box(_ table: [SIMD3<Double>], _ c: (Int, Int, Int, Int)) -> SIMD3<Double> {
            let positive: SIMD3<Double> = table[c.0] + table[c.3]
            let negative: SIMD3<Double> = table[c.1] + table[c.2]
            return positive - negative
        }

        func at(row: Int, column: Int) -> (mean: SIMD3<Float>, spread: Float)? {
            var radius = max(2, height / 10)
            while true {
                let top = max(0, row - radius), bottom = min(height, row + radius + 1)
                let left = max(0, column - radius), right = min(width, column + radius + 1)
                let window = corners(top, left, bottom, right)
                let count = box(counts, window)
                if count >= 4 || radius >= max(width, height) {
                    guard count > 0 else { return nil }
                    let mean: SIMD3<Double> = box(sums, window) / count
                    let meanSquare: Double = (mean * mean).sum()
                    let variance = max(0, box(squares, window) / count - meanSquare)
                    return (SIMD3<Float>(Float(mean.x), Float(mean.y), Float(mean.z)), Float(variance.squareRoot()))
                }
                radius *= 2
            }
        }
    }

    static func smooth(_ x: Float) -> Float {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// An sRGB-encoded color (0...255) in Oklab.
    static func oklab(red: UInt8, green: UInt8, blue: UInt8) -> SIMD3<Float> {
        func linear(_ v: UInt8) -> Float {
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let okL: Float = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let okA: Float = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let okB: Float = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return SIMD3<Float>(okL, okA, okB)
    }
}
