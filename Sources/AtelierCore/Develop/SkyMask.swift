import Foundation

/// Select Sky (AT-068) from the depth model's field and the photo's colors on the same grid.
///
/// Depth alone can't tell a distant skyline from the sky (both read as "farthest"), nor find sky
/// seen through gaps in a nearer object (a tower's lattice). So depth only finds the sky that is
/// certain, and the sky's own colors decide the rest (Rosh's Eiffel Tower photo, Nov 15, 2026):
/// 1. Certain sky: the very farthest depths (at least `seedDepth`) connected to the top row.
/// 2. The sky's colors, in Oklab, band by band from top to bottom, so a sunset gradient counts:
///    each band's mean and spread from the certain sky in it (bands below the lowest certain sky
///    use the lowest band with some).
/// 3. Every pixel that is far enough (`farGate`) and close to its band's sky color is sky, so a
///    dark skyline drops out and sky behind the tower comes in. Nothing below the lowest certain
///    sky (plus a little) is taken, so water reflecting the sky isn't.
extension DepthMap.Field {
    static let seedDepth: Float = 0.985
    static let farGate: (low: Float, high: Float) = (0.72, 0.88)
    static let bands = 12

    /// Select Sky's mask, 0...1, on the field's grid; all zero when no certain sky touches the top.
    public var sky: [Float] {
        let count = width * height
        guard values.count == count else { return [] }
        let seeds = skySeeds()
        guard seeds.contains(true) else { return [Float](repeating: 0, count: count) }
        // Without the photo's colors, the certain sky is all there is.
        guard colors.count == count * 4 else { return seeds.map { $0 ? 1 : 0 } }
        var labs = [SIMD3<Float>](repeating: .zero, count: count)
        for i in 0..<count {
            labs[i] = Self.oklab(red: colors[i * 4], green: colors[i * 4 + 1], blue: colors[i * 4 + 2])
        }
        let stats = bandStats(labs: labs, seeds: seeds)
        var lowestSeedRow = 0
        for i in 0..<count where seeds[i] { lowestSeedRow = max(lowestSeedRow, i / width) }
        let lastRow = min(height - 1, lowestSeedRow + max(1, height / 50))
        var out = [Float](repeating: 0, count: count)
        for row in 0...lastRow {
            let (mean, reach) = stats(row)
            for column in 0..<width {
                let i = row * width + column
                let far = Self.smooth((values[i] - Self.farGate.low) / (Self.farGate.high - Self.farGate.low))
                guard far > 0 else { continue }
                let d = labs[i] - mean
                let distance = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
                let color = Self.smooth((reach - distance) / (reach * 0.5))
                out[i] = far * color
            }
        }
        return out
    }

    /// The certain sky: depths of at least `seedDepth` connected to the top row through such depths.
    func skySeeds() -> [Bool] {
        var reached = [Bool](repeating: false, count: values.count)
        var stack: [Int] = []
        for column in 0..<width where values[column] >= Self.seedDepth {
            reached[column] = true
            stack.append(column)
        }
        while let index = stack.popLast() {
            let row = index / width, column = index % width
            var neighbors: [Int] = []
            if row > 0 { neighbors.append(index - width) }
            if row < height - 1 { neighbors.append(index + width) }
            if column > 0 { neighbors.append(index - 1) }
            if column < width - 1 { neighbors.append(index + 1) }
            for next in neighbors where !reached[next] && values[next] >= Self.seedDepth {
                reached[next] = true
                stack.append(next)
            }
        }
        return reached
    }

    /// For each row, the sky's color there (interpolated between band centers) and how far from
    /// it a color still counts (fully within half of that).
    func bandStats(labs: [SIMD3<Float>], seeds: [Bool]) -> (Int) -> (SIMD3<Float>, Float) {
        let bandCount = max(1, min(Self.bands, height))
        var sums = [SIMD3<Float>](repeating: .zero, count: bandCount)
        var counts = [Int](repeating: 0, count: bandCount)
        func band(_ row: Int) -> Int { min(bandCount - 1, row * bandCount / height) }
        for i in seeds.indices where seeds[i] {
            let b = band(i / width)
            sums[b] += labs[i]
            counts[b] += 1
        }
        var means = [SIMD3<Float>?](repeating: nil, count: bandCount)
        for b in 0..<bandCount where counts[b] > 0 { means[b] = sums[b] / Float(counts[b]) }
        var squares = [Float](repeating: 0, count: bandCount)
        for i in seeds.indices where seeds[i] {
            let b = band(i / width)
            guard let mean = means[b] else { continue }
            let d = labs[i] - mean
            squares[b] += d.x * d.x + d.y * d.y + d.z * d.z
        }
        var reaches = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount where counts[b] > 0 {
            let spread = (squares[b] / Float(counts[b])).squareRoot()
            reaches[b] = 0.045 + 2.5 * min(spread, 0.06)
        }
        // Bands without certain sky take the nearest band that has some (above first).
        var filledMeans = [SIMD3<Float>](repeating: .zero, count: bandCount)
        var filledReaches = [Float](repeating: 0.045, count: bandCount)
        for b in 0..<bandCount {
            var source: Int?
            for distance in 0..<bandCount {
                if b - distance >= 0, means[b - distance] != nil { source = b - distance; break }
                if b + distance < bandCount, means[b + distance] != nil { source = b + distance; break }
            }
            if let source, let mean = means[source] {
                filledMeans[b] = mean
                filledReaches[b] = reaches[source]
            }
        }
        let rowsPerBand = Float(height) / Float(bandCount)
        return { row in
            // Between the centers of the two nearest bands.
            let position = (Float(row) + 0.5) / rowsPerBand - 0.5
            let lower = min(bandCount - 1, max(0, Int(position.rounded(.down))))
            let upper = min(bandCount - 1, lower + 1)
            let t = min(1, max(0, position - Float(lower)))
            let mean = filledMeans[lower] * (1 - t) + filledMeans[upper] * t
            let reach = filledReaches[lower] * (1 - t) + filledReaches[upper] * t
            return (mean, reach)
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
