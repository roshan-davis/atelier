import Foundation

/// Content-Aware Remove's fill (AT-066 step 3): image completion with PatchMatch.
///
/// The hole is filled coarse to fine. At each size, every 7 × 7 patch that touches the hole
/// finds the most alike patch wholly outside it (PatchMatch: Barnes, Shechtman, Finkelstein and
/// Goldman, "PatchMatch: A Randomized Correspondence Algorithm for Structural Image Editing",
/// SIGGRAPH 2009), and each hole pixel becomes the weighted mean of what the patches over it say
/// (Wexler, Shechtman and Irani, "Space-Time Completion of Video", IEEE TPAMI 2007). The last
/// pass takes each pixel from its own best match, so grain and fine texture stay sharp.
///
/// Pure Swift on plain arrays, so it is tested without a photo; deterministic for a seed.
public enum ContentAwareFill {
    /// RGB values row by row from the top, three per pixel.
    public struct Pixels: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var rgb: [Float]

        public init(width: Int, height: Int, rgb: [Float]) {
            self.width = width
            self.height = height
            self.rgb = rgb
        }
    }

    static let patch = 7
    static let half = patch / 2

    /// Asks the photo for a new render once a fill computed in the background is in.
    public static let fillReady = Notification.Name("AtelierContentAwareFillReady")

    /// `pixels` with every pixel where `hole` is true (row by row, as `pixels`) filled from
    /// the rest. Unchanged when there is no hole or nothing to fill it from.
    public static func fill(_ pixels: Pixels, hole: [Bool], seed: UInt64 = 1) -> Pixels {
        let count = pixels.width * pixels.height
        guard count > 0, hole.count == count, pixels.rgb.count == count * 3, hole.contains(true) else { return pixels }
        var random = SplitMix64(seed: seed)
        // The pyramid, full size first, down until the hole is about a patch across.
        var levels = [Level(width: pixels.width, height: pixels.height, rgb: pixels.rgb, hole: hole)]
        while let last = levels.last, min(last.width, last.height) >= 4 * patch, last.holeSpan > patch {
            levels.append(last.halved())
        }
        var current = levels[levels.count - 1]
        current.diffuseHole()
        var matches: [Int32] = []
        for index in stride(from: levels.count - 1, through: 0, by: -1) {
            var level = levels[index]
            if index < levels.count - 1 {
                level.takeHole(from: current)
                matches = level.upsampled(matches, from: current)
            } else {
                level = current
                matches = [Int32](repeating: -1, count: level.width * level.height)
            }
            let iterations = index == 0 ? 4 : (index == levels.count - 1 ? 12 : 6)
            level.complete(matches: &matches, iterations: iterations, sharpen: index == 0, random: &random)
            current = level
        }
        return Pixels(width: pixels.width, height: pixels.height, rgb: current.rgb)
    }

    /// One size of the pyramid.
    struct Level {
        let width: Int
        let height: Int
        var rgb: [Float]
        let hole: [Bool]

        /// The hole's larger side, in pixels.
        var holeSpan: Int {
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                for x in 0..<width where hole[y * width + x] {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return maxX < 0 ? 0 : max(maxX - minX, maxY - minY) + 1
        }

        /// Half the size: each pixel the mean of four, in the hole if any of the four is.
        func halved() -> Level {
            let w = width / 2, h = height / 2
            var rgb = [Float](repeating: 0, count: w * h * 3)
            var hole = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let a = (2 * y) * width + 2 * x, b = a + 1, c = a + width, d = c + 1
                    for k in 0..<3 {
                        rgb[(y * w + x) * 3 + k] = (self.rgb[a * 3 + k] + self.rgb[b * 3 + k]
                            + self.rgb[c * 3 + k] + self.rgb[d * 3 + k]) / 4
                    }
                    hole[y * w + x] = self.hole[a] || self.hole[b] || self.hole[c] || self.hole[d]
                }
            }
            return Level(width: w, height: h, rgb: rgb, hole: hole)
        }

        /// A smooth first guess for the coarsest hole: the known pixels' mean, then repeated
        /// averaging of each hole pixel's neighbors.
        mutating func diffuseHole() {
            var sum = [Float](repeating: 0, count: 3), known = 0
            for i in 0..<hole.count where !hole[i] {
                for k in 0..<3 { sum[k] += rgb[i * 3 + k] }
                known += 1
            }
            guard known > 0 else { return }
            for i in 0..<hole.count where hole[i] {
                for k in 0..<3 { rgb[i * 3 + k] = sum[k] / Float(known) }
            }
            for _ in 0..<(2 * max(width, height)) {
                for y in 0..<height {
                    for x in 0..<width where hole[y * width + x] {
                        var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
                        for side in 0..<4 {
                            let nx = x + (side == 0 ? -1 : side == 1 ? 1 : 0)
                            let ny = y + (side == 2 ? -1 : side == 3 ? 1 : 0)
                            guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                            let j = (ny * width + nx) * 3
                            r += rgb[j]; g += rgb[j + 1]; b += rgb[j + 2]
                            n += 1
                        }
                        let i = (y * width + x) * 3
                        if n > 0 { rgb[i] = r / n; rgb[i + 1] = g / n; rgb[i + 2] = b / n }
                    }
                }
            }
        }

        /// The hole's pixels from the coarser `level`'s result, scaled up.
        mutating func takeHole(from coarse: Level) {
            for y in 0..<height {
                for x in 0..<width where hole[y * width + x] {
                    let cx = min(x / 2, coarse.width - 1), cy = min(y / 2, coarse.height - 1)
                    for k in 0..<3 { rgb[(y * width + x) * 3 + k] = coarse.rgb[(cy * coarse.width + cx) * 3 + k] }
                }
            }
        }

        /// The coarser level's matches at this size: twice as far, plus the pixel's place in
        /// its 2 × 2 block. Invalid ones are replaced when the level starts.
        func upsampled(_ matches: [Int32], from coarse: Level) -> [Int32] {
            var result = [Int32](repeating: -1, count: width * height)
            guard matches.count == coarse.width * coarse.height else { return result }
            for y in 0..<height {
                for x in 0..<width {
                    let cx = x / 2, cy = y / 2
                    guard cx < coarse.width, cy < coarse.height else { continue }
                    let m = Int(matches[cy * coarse.width + cx])
                    guard m >= 0 else { continue }
                    let sx = min(width - 1, 2 * (m % coarse.width) + x % 2)
                    let sy = min(height - 1, 2 * (m / coarse.width) + y % 2)
                    result[y * width + x] = Int32(sy * width + sx)
                }
            }
            return result
        }

        /// `mask` grown by `radius` pixels in every direction (a square).
        static func dilated(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
            var rows = [Bool](repeating: false, count: mask.count)
            for y in 0..<height {
                for x in 0..<width where mask[y * width + x] {
                    for dx in max(0, x - radius)...min(width - 1, x + radius) { rows[y * width + dx] = true }
                }
            }
            var result = [Bool](repeating: false, count: mask.count)
            for y in 0..<height {
                for x in 0..<width where rows[y * width + x] {
                    for dy in max(0, y - radius)...min(height - 1, y + radius) { result[dy * width + x] = true }
                }
            }
            return result
        }

        /// PatchMatch and voting at this size.
        mutating func complete(matches: inout [Int32], iterations: Int, sharpen: Bool, random: inout SplitMix64) {
            let half = ContentAwareFill.half
            guard width > 2 * half, height > 2 * half else { return }
            let touched = Self.dilated(hole, width: width, height: height, radius: half)
            var valid = [Bool](repeating: false, count: width * height)
            var sources: [Int32] = []
            var targets: [Int32] = []
            for y in half..<(height - half) {
                for x in half..<(width - half) {
                    let i = y * width + x
                    if touched[i] {
                        targets.append(Int32(i))
                    } else {
                        valid[i] = true
                        sources.append(Int32(i))
                    }
                }
            }
            guard !sources.isEmpty, !targets.isEmpty else { return }
            if matches.count != width * height { matches = [Int32](repeating: -1, count: width * height) }
            var distances = [Float](repeating: 0, count: width * height)
            let w = width, h = height
            for _ in 0..<iterations {
                for t in targets {
                    let m = Int(matches[Int(t)])
                    if m < 0 || !valid[m] { matches[Int(t)] = sources[random.below(sources.count)] }
                    distances[Int(t)] = distance(Int(t), Int(matches[Int(t)]), limit: .infinity)
                }
                for pass in 0..<2 {
                    let step = pass == 0 ? 1 : -1
                    let order: [Int32] = pass == 0 ? targets : Array(targets.reversed())
                    for t32 in order {
                        let t = Int(t32), tx = t % w, ty = t / w
                        var best = Int(matches[t]), bestDistance = distances[t]
                        // Propagation: the neighbor's match, moved by one.
                        for side in 0..<2 {
                            let nx = side == 0 ? tx - step : tx, ny = side == 0 ? ty : ty - step
                            guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                            let m = Int(matches[ny * w + nx])
                            guard m >= 0, touched[ny * w + nx] else { continue }
                            let cx = m % w + (tx - nx), cy = m / w + (ty - ny)
                            guard cx >= 0, cy >= 0, cx < w, cy < h, valid[cy * w + cx] else { continue }
                            let candidate = cy * w + cx
                            let d = distance(t, candidate, limit: bestDistance)
                            if d < bestDistance { best = candidate; bestDistance = d }
                        }
                        // Random search around the best, the window halving each time.
                        var radius = max(w, h)
                        while radius >= 1 {
                            let cx = best % w + random.between(-radius, radius)
                            let cy = best / w + random.between(-radius, radius)
                            if cx >= 0, cy >= 0, cx < w, cy < h, valid[cy * w + cx] {
                                let candidate = cy * w + cx
                                let d = distance(t, candidate, limit: bestDistance)
                                if d < bestDistance { best = candidate; bestDistance = d }
                            }
                            radius /= 2
                        }
                        matches[t] = Int32(best)
                        distances[t] = bestDistance
                    }
                }
                vote(targets: targets, matches: matches, distances: distances)
            }
            if sharpen {
                // Each hole pixel from the middle of its own best match.
                var sharp = rgb
                for t32 in targets {
                    let t = Int(t32)
                    guard hole[t] else { continue }
                    let m = Int(matches[t])
                    for k in 0..<3 { sharp[t * 3 + k] = rgb[m * 3 + k] }
                }
                rgb = sharp
            }
        }

        /// Every hole pixel becomes the mean of the matching pixels of the patches over it,
        /// closer matches counting more.
        private mutating func vote(targets: [Int32], matches: [Int32], distances: [Float]) {
            let half = ContentAwareFill.half, w = width
            var sorted = targets.map { distances[Int($0)] }
            sorted.sort()
            let sigma2 = max(sorted[sorted.count / 2], 1e-6)
            var sum = [Float](repeating: 0, count: rgb.count)
            var weights = [Float](repeating: 0, count: hole.count)
            for t32 in targets {
                let t = Int(t32), m = Int(matches[t])
                let weight = exp(-distances[t] / (2 * sigma2))
                let tx = t % w, ty = t / w, mx = m % w, my = m / w
                for dy in -half...half {
                    for dx in -half...half {
                        let q = (ty + dy) * w + tx + dx
                        guard hole[q] else { continue }
                        let s = (my + dy) * w + mx + dx
                        for k in 0..<3 { sum[q * 3 + k] += weight * rgb[s * 3 + k] }
                        weights[q] += weight
                    }
                }
            }
            for q in 0..<hole.count where hole[q] && weights[q] > 0 {
                for k in 0..<3 { rgb[q * 3 + k] = sum[q * 3 + k] / weights[q] }
            }
        }

        /// Sum of squared differences between the patches centered at `a` and `b`, stopping
        /// early once it passes `limit`.
        private func distance(_ a: Int, _ b: Int, limit: Float) -> Float {
            let half = ContentAwareFill.half, w = width
            return rgb.withUnsafeBufferPointer { p in
                var total: Float = 0
                for dy in -half...half {
                    let rowA = (a + dy * w - half) * 3, rowB = (b + dy * w - half) * 3
                    for i in 0..<(ContentAwareFill.patch * 3) {
                        let d = p[rowA + i] - p[rowB + i]
                        total += d * d
                    }
                    if total >= limit { return total }
                }
                return total
            }
        }
    }

    /// A small, fast, seedable random generator (Steele, Lea and Flood, "Fast Splittable
    /// Pseudorandom Number Generators", OOPSLA 2014), so a fill is the same in every render.
    struct SplitMix64 {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 0..<n.
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }

        /// lower...upper.
        mutating func between(_ lower: Int, _ upper: Int) -> Int { lower + below(upper - lower + 1) }
    }
}
