import CoreGraphics
import CoreImage
import Foundation

/// Content-Aware fills for one open photo (AT-066 step 3), each found once and kept.
///
/// A fill depends on the photo under the spot (the corrected photo and every spot before it)
/// and on the spot's path, size and variation, not on its feather or opacity, so moving those
/// sliders, or any tone or color slider, never fills again. In the editor a new fill is found in
/// the background while the spot shows Heal, and `ContentAwareFill.fillReady` asks for a new
/// render once it is in; exports wait for it.
final class SpotFills: @unchecked Sendable {
    struct Key: Hashable {
        /// Which corrected photo the spots were drawn on (see `DevelopSession`).
        let upstream: Int
        /// The spots drawn before this one, which change the pixels it is filled from.
        let prior: [DevelopSettings.Spot]
        let points: [DevelopSettings.MaskPoint]
        let size: Double
        let variation: Int
        let width: Int
        let height: Int
    }

    private let context: CIContext
    /// Whether to wait for a fill (export) instead of finding it in the background (editor).
    private let waits: Bool
    private var fills: [Key: CIImage] = [:]
    private var pending: Set<Key> = []
    private let lock = NSLock()

    init(context: CIContext, waits: Bool) {
        self.context = context
        self.waits = waits
    }

    /// The fill for `spot` on `image` (the photo with the spots before it, uncropped), placed
    /// on the photo, or nil while it is being found.
    func fill(for spot: DevelopSettings.Spot, prior: [DevelopSettings.Spot], upstream: Int,
              image: CIImage) -> CIImage? {
        let extent = image.extent
        let key = Key(upstream: upstream, prior: prior, points: spot.points, size: spot.size, variation: spot.variation,
                      width: Int(extent.width.rounded()), height: Int(extent.height.rounded()))
        lock.lock()
        if let found = fills[key] {
            lock.unlock()
            return found
        }
        if pending.contains(key) {
            lock.unlock()
            return nil
        }
        if !waits { pending.insert(key) }
        lock.unlock()
        guard !waits else {
            let found = Self.find(spot, on: image, context: context)
            store(found, for: key)
            return found
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let found = Self.find(spot, on: image, context: self.context)
            self.lock.lock()
            self.pending.remove(key)
            self.lock.unlock()
            self.store(found, for: key)
            DispatchQueue.main.async { NotificationCenter.default.post(name: ContentAwareFill.fillReady, object: nil) }
        }
        return nil
    }

    private func store(_ fill: CIImage?, for key: Key) {
        guard let fill else { return }
        lock.lock()
        defer { lock.unlock() }
        // Dust can mean dozens of spots; a few photos' worth are kept.
        if fills.count >= 120 { fills.removeAll() }
        fills[key] = fill
    }

    /// Longest side of the area a fill is found in; a larger area is worked on scaled down.
    static let workingSize = 1024

    /// Renders the area around the spot, fills the spot's brush there and returns the area,
    /// placed on the photo. Nil when the area can't be read.
    static func find(_ spot: DevelopSettings.Spot, on image: CIImage, context: CIContext) -> CIImage? {
        let extent = image.extent
        let photo = extent.size
        guard photo.width >= 1, photo.height >= 1, !spot.points.isEmpty else { return nil }
        let radius = CGFloat(spot.size) * max(photo.width, photo.height) / 2
        // Room around the spot to take texture from: twice its radius on every side.
        let window = spot.bounds(in: photo, margin: max(16, radius * 2)).integral
            .intersection(CGRect(origin: .zero, size: photo))
        guard !window.isNull, window.width >= 4, window.height >= 4 else { return nil }
        let scale = min(1, CGFloat(workingSize) / max(window.width, window.height))
        let width = max(1, Int((window.width * scale).rounded())), height = max(1, Int((window.height * scale).rounded()))
        // Core Image's y axis points up.
        let region = CGRect(x: extent.minX + window.minX, y: extent.minY + photo.height - window.maxY,
                            width: window.width, height: window.height)
        let local = image.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / region.width, y: CGFloat(height) / region.height))
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let cgImage = context.createCGImage(local, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                  format: .RGBAf, colorSpace: space),
              var pixels = readRGB(cgImage) else { return nil }
        // The hole: every pixel within the brush's radius (plus one) of the spot's path.
        let path = spot.points.map {
            CGPoint(x: (CGFloat($0.x) * photo.width - window.minX) * scale, y: (CGFloat($0.y) * photo.height - window.minY) * scale)
        }
        let reach = radius * scale + 1
        var hole = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where distance(from: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5), to: path) <= reach {
                hole[y * width + x] = true
            }
        }
        let seed = 0x5EED_0000 &+ UInt64(truncatingIfNeeded: spot.variation) &* 0x9E37_79B9
        pixels = ContentAwareFill.fill(pixels, hole: hole, seed: seed)
        guard let filled = makeImage(pixels, space: space) else { return nil }
        return CIImage(cgImage: filled)
            .transformed(by: CGAffineTransform(scaleX: region.width / CGFloat(width), y: region.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
            .cropped(to: region)
    }

    /// Distance from `p` to the nearest point of the polyline `path`.
    static func distance(from p: CGPoint, to path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return .infinity }
        var best = hypot(p.x - first.x, p.y - first.y)
        for (a, b) in zip(path, path.dropFirst()) {
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let length = ab.x * ab.x + ab.y * ab.y
            let t = length > 0 ? min(1, max(0, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / length)) : 0
            best = min(best, hypot(p.x - (a.x + ab.x * t), p.y - (a.y + ab.y * t)))
        }
        return best
    }

    /// The RGB values of a 32-bit float RGBA image, rows from the top.
    static func readRGB(_ image: CGImage) -> ContentAwareFill.Pixels? {
        guard image.bitsPerComponent == 32, image.bitsPerPixel == 128,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let width = image.width, height = image.height, rowBytes = image.bytesPerRow
        guard CFDataGetLength(data) >= rowBytes * height else { return nil }
        let bigEndian = image.bitmapInfo.contains(.byteOrder32Big)
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                for k in 0..<3 {
                    var bits: UInt32 = 0
                    memcpy(&bits, row + (x * 4 + k) * 4, 4)
                    rgb[(y * width + x) * 3 + k] = Float(bitPattern: bigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits))
                }
            }
        }
        return ContentAwareFill.Pixels(width: width, height: height, rgb: rgb)
    }

    /// An opaque 32-bit float RGBA image of `pixels` in `space`.
    static func makeImage(_ pixels: ContentAwareFill.Pixels, space: CGColorSpace) -> CGImage? {
        var rgba = [Float](repeating: 1, count: pixels.width * pixels.height * 4)
        for i in 0..<(pixels.width * pixels.height) {
            rgba[i * 4] = pixels.rgb[i * 3]
            rgba[i * 4 + 1] = pixels.rgb[i * 3 + 1]
            rgba[i * 4 + 2] = pixels.rgb[i * 3 + 2]
        }
        let data = rgba.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.floatComponents).union(.byteOrder32Little)
        return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 32, bitsPerPixel: 128,
                       bytesPerRow: pixels.width * 16, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
