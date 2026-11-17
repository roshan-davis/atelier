import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Smart previews (AT-079d, feasibility spike): a 2560 px linear DNG of a photo, kept on this Mac,
/// that Develop can edit while the original is offline. macOS reads DNG but can't write it, so
/// this writes the TIFF/DNG container itself.
///
/// The pixels are the photo as CIRAWFilter decodes it (demosaiced, in linear Rec. 2020), with the
/// as-shot white balance taken back out, so the DNG is "LinearRaw" camera data whose camera space
/// is Rec. 2020: `ColorMatrix1` is XYZ (D65) → Rec. 2020 and `AsShotNeutral` the as-shot white in
/// it. CIRAWFilter then white-balances and exposes it as it does a RAW, so Temp, Tint and Exposure
/// keep working. It is decoded linear (no tone curve, shadow boost or baseline exposure), since
/// opening the DNG applies those again; the RAW's baseline exposure goes in `BaselineExposure`,
/// plus one stop for the highlight headroom kept by storing half the value.
///
/// Two encodings, for the spike to compare: lossless 16-bit, and Lightroom-style lossy (8-bit
/// JPEG tiles through a `LinearizationTable`, DNG 1.4 compression 34892).
public enum SmartPreviewDNG {
    public enum Encoding: Sendable, Equatable {
        case lossless16
        case lossyJPEG(quality: Double)
    }

    public static let longEdge = 2560
    static let headroom: Float = 2
    static let tile = 256

    /// XYZ (D65) → linear Rec. 2020.
    static let xyzToRec2020: [Double] = [
        1.7166512, -0.3556708, -0.2533663,
        -0.6666844, 1.6164812, 0.0157685,
        0.0176399, -0.0427706, 0.9421031,
    ]

    // MARK: From a RAW

    /// Decodes `raw` at the smart preview's size with its as-shot settings and writes the DNG.
    /// Returns the as-shot temperature and tint used.
    @discardableResult
    public static func make(from raw: URL, to url: URL, encoding: Encoding,
                            context: CIContext = CIContext(options: [.cacheIntermediates: false])) throws -> (temperature: Double, tint: Double) {
        guard let filter = CIRAWFilter(imageURL: raw) else { throw CocoaError(.fileReadCorruptFile) }
        let native = filter.nativeSize
        let edge = max(native.width, native.height)
        if edge > CGFloat(longEdge) { filter.scaleFactor = Float(CGFloat(longEdge) / edge) }
        let temperature = Double(filter.neutralTemperature)
        let tint = Double(filter.neutralTint)
        // The as-shot white straight from the RAW engine, so no temperature/tint convention can
        // differ (Apple's tint sign is the opposite of `whiteXY`'s).
        let white = filter.neutralChromaticity
        // Linear scene data only: Apple's tone curve, shadow boost and the camera's baseline
        // exposure are applied again when the DNG is opened, so they must not be baked in.
        let baseline = Double(filter.baselineExposure)
        filter.baselineExposure = 0
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        guard let image = filter.outputImage else { throw CocoaError(.fileReadCorruptFile) }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.linearITUR_2020)!
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent,
                           format: .RGBAf, colorSpace: space)
        }
        let model = (CGImageSourceCreateWithURL(raw as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyTIFFDictionary]
            as? [CFString: Any])
        let make = model?[kCGImagePropertyTIFFMake] as? String ?? "Atelier"
        let camera = model?[kCGImagePropertyTIFFModel] as? String ?? "Smart Preview"
        try write(rgba: pixels, width: width, height: height, neutral: neutral(x: Double(white.x), y: Double(white.y)),
                  make: make, model: camera, encoding: encoding, baselineExposure: baseline, to: url)
        return (temperature, tint)
    }

    // MARK: White

    /// The as-shot white in Rec. 2020 (max 1): what a white surface reads under that light.
    public static func neutral(temperature: Double, tint: Double) -> SIMD3<Double> {
        let (x, y) = whiteXY(temperature: temperature, tint: tint)
        return neutral(x: x, y: y)
    }

    /// The white of chromaticity (x, y) in Rec. 2020 (max 1).
    public static func neutral(x: Double, y: Double) -> SIMD3<Double> {
        let xyz = SIMD3(x / y, 1, (1 - x - y) / y)
        let m = xyzToRec2020
        var rgb = SIMD3(m[0] * xyz.x + m[1] * xyz.y + m[2] * xyz.z,
                        m[3] * xyz.x + m[4] * xyz.y + m[5] * xyz.z,
                        m[6] * xyz.x + m[7] * xyz.y + m[8] * xyz.z)
        // Relative to D65, the space's white, which reads (1, 1, 1).
        let d65 = SIMD3(m[0] * 0.95047 + m[1] + m[2] * 1.08883,
                        m[3] * 0.95047 + m[4] + m[5] * 1.08883,
                        m[6] * 0.95047 + m[7] + m[8] * 1.08883)
        rgb /= d65
        return rgb / max(rgb.x, rgb.y, rgb.z)
    }

    /// Correlated colour temperature and Adobe-style tint → chromaticity: Kang et al. (2002) for
    /// the Planckian locus, tint as an offset across it in CIE 1960 uv (3000 tint = 1 uv unit,
    /// positive towards magenta), as the DNG SDK does.
    public static func whiteXY(temperature: Double, tint: Double) -> (Double, Double) {
        func planck(_ t: Double) -> (Double, Double) {
            let t = min(25000, max(1667, t))
            let x = t <= 4000
                ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
                : -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
            let y: Double
            if t <= 2222 {
                y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
            } else if t <= 4000 {
                y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
            } else {
                y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
            }
            return (x, y)
        }
        func uv(_ p: (Double, Double)) -> (Double, Double) {
            let d = -2 * p.0 + 12 * p.1 + 3
            return (4 * p.0 / d, 6 * p.1 / d)
        }
        let here = uv(planck(temperature))
        let next = uv(planck(temperature + 50))
        var normal = (-(next.1 - here.1), next.0 - here.0)
        let length = (normal.0 * normal.0 + normal.1 * normal.1).squareRoot()
        normal = (normal.0 / length, normal.1 / length)
        if normal.1 < 0 { normal = (-normal.0, -normal.1) }  // towards green (+v)
        let offset = -tint / 3000
        let u = here.0 + normal.0 * offset, v = here.1 + normal.1 * offset
        let d = 2 * u - 8 * v + 4
        return (3 * u / d, 2 * v / d)
    }

    // MARK: Writing

    /// Writes white-balanced linear Rec. 2020 RGBA floats as LinearRaw camera data.
    public static func write(rgba: [Float], width: Int, height: Int, neutral: SIMD3<Double>,
                             make: String, model: String, encoding: Encoding, baselineExposure: Double = 0,
                             to url: URL) throws {
        let gains = SIMD3<Float>(Float(neutral.x), Float(neutral.y), Float(neutral.z)) / headroom
        var tiff = TIFFWriter()
        var entries: [TIFFWriter.Entry] = []
        // Tiles no bigger than the photo (rounded up to JPEG's 16-pixel blocks).
        let tileWidth = min(tile, (width + 15) / 16 * 16), tileHeight = min(tile, (height + 15) / 16 * 16)
        let tilesAcross = (width + tileWidth - 1) / tileWidth, tilesDown = (height + tileHeight - 1) / tileHeight
        var tileOffsets: [UInt32] = [], tileCounts: [UInt32] = []

        switch encoding {
        case .lossless16:
            for ty in 0..<tilesDown {
                for tx in 0..<tilesAcross {
                    var data = Data(capacity: tileWidth * tileHeight * 6)
                    for row in 0..<tileHeight {
                        for col in 0..<tileWidth {
                            let x = min(width - 1, tx * tileWidth + col), y = min(height - 1, ty * tileHeight + row)
                            let i = (y * width + x) * 4
                            for c in 0..<3 {
                                let value = max(0, min(1, rgba[i + c] * gains[c]))
                                var word = UInt16(value * 65535 + 0.5).littleEndian
                                withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
                            }
                        }
                    }
                    tileOffsets.append(tiff.append(data))
                    tileCounts.append(UInt32(data.count))
                }
            }
            entries += [.shorts(258, [16, 16, 16]), .short(259, 1)]
        case .lossyJPEG(let quality):
            for ty in 0..<tilesDown {
                for tx in 0..<tilesAcross {
                    var bytes = [UInt8](repeating: 0, count: tileWidth * tileHeight * 3)
                    for row in 0..<tileHeight {
                        for col in 0..<tileWidth {
                            let x = min(width - 1, tx * tileWidth + col), y = min(height - 1, ty * tileHeight + row)
                            let i = (y * width + x) * 4
                            for c in 0..<3 {
                                let linear = max(0, min(1, rgba[i + c] * gains[c]))
                                bytes[(row * tileWidth + col) * 3 + c] = UInt8(pow(linear, 1 / 2.2) * 255 + 0.5)
                            }
                        }
                    }
                    let data = try jpeg(bytes, width: tileWidth, height: tileHeight, quality: quality)
                    tileOffsets.append(tiff.append(data))
                    tileCounts.append(UInt32(data.count))
                }
            }
            let table = (0..<256).map { UInt16(min(65535, pow(Double($0) / 255, 2.2) * 65535 + 0.5)) }
            entries += [.shorts(258, [8, 8, 8]), .short(259, 34892), .shorts(50712, table)]
        }

        let m = xyzToRec2020
        entries += [
            .long(254, 0), .long(256, UInt32(width)), .long(257, UInt32(height)),
            .short(262, 34892), .ascii(271, make), .ascii(272, model), .short(274, 1),
            .short(277, 3), .short(284, 1), .ascii(305, "Atelier"),
            .long(322, UInt32(tileWidth)), .long(323, UInt32(tileHeight)),
            .longs(324, tileOffsets), .longs(325, tileCounts),
            .bytes(50706, [1, 4, 0, 0]), .bytes(50707, [1, 1, 0, 0]),
            .ascii(50708, "\(make) \(model) (Atelier Smart Preview)"),
            .longs(50714, [0, 0, 0]), .longs(50717, [65535, 65535, 65535]),
            .srationals(50721, m.map { Int32(($0 * 10000).rounded()) }, denominator: 10000),
            .rationals(50728, [neutral.x, neutral.y, neutral.z].map { UInt32(($0 * 1_000_000).rounded()) }, denominator: 1_000_000),
            .srationals(50730, [Int32(((baselineExposure + Double(log2(headroom))) * 1000).rounded())], denominator: 1000),
            .short(50778, 21),
        ]
        try tiff.finish(entries).write(to: url)
    }

    static func jpeg(_ rgb: [UInt8], width: Int, height: Int, quality: Double) throws -> Data {
        let provider = CGDataProvider(data: Data(rgb) as CFData)!
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return out as Data
    }
}

/// A little-endian TIFF with one IFD, data first (word-aligned), the IFD last.
struct TIFFWriter {
    enum Entry {
        case short(UInt16, UInt16)
        case shorts(UInt16, [UInt16])
        case long(UInt16, UInt32)
        case longs(UInt16, [UInt32])
        case bytes(UInt16, [UInt8])
        case ascii(UInt16, String)
        case rationals(UInt16, [UInt32], denominator: UInt32)
        case srationals(UInt16, [Int32], denominator: Int32)

        var tag: UInt16 {
            switch self {
            case .short(let t, _), .shorts(let t, _), .long(let t, _), .longs(let t, _), .bytes(let t, _),
                 .ascii(let t, _), .rationals(let t, _, _), .srationals(let t, _, _): return t
            }
        }

        /// TIFF type, count, value bytes.
        var encoded: (UInt16, UInt32, Data) {
            var data = Data()
            func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
            switch self {
            case .short(_, let v): put(v); return (3, 1, data)
            case .shorts(_, let v): v.forEach(put); return (3, UInt32(v.count), data)
            case .long(_, let v): put(v); return (4, 1, data)
            case .longs(_, let v): v.forEach(put); return (4, UInt32(v.count), data)
            case .bytes(_, let v): data.append(contentsOf: v); return (1, UInt32(v.count), data)
            case .ascii(_, let s): data.append(contentsOf: Array(s.utf8) + [0]); return (2, UInt32(data.count), data)
            case .rationals(_, let v, let d): v.forEach { put($0); put(d) }; return (5, UInt32(v.count), data)
            case .srationals(_, let v, let d): v.forEach { put($0); put(d) }; return (10, UInt32(v.count), data)
            }
        }
    }

    private(set) var body = Data([0x49, 0x49, 42, 0, 0, 0, 0, 0])

    /// Appends a block (tile data or an out-of-line value) and returns its offset.
    mutating func append(_ data: Data) -> UInt32 {
        if body.count % 2 == 1 { body.append(0) }
        let offset = UInt32(body.count)
        body.append(data)
        return offset
    }

    mutating func finish(_ entries: [Entry]) -> Data {
        let sorted = entries.sorted { $0.tag < $1.tag }
        let values: [(UInt16, UInt32, Data)] = sorted.map(\.encoded)
        var outOfLine: [Int: UInt32] = [:]
        for (index, value) in values.enumerated() where value.2.count > 4 {
            outOfLine[index] = append(value.2)
        }
        if body.count % 2 == 1 { body.append(0) }
        let ifd = UInt32(body.count)
        body.replaceSubrange(4..<8, with: withUnsafeBytes(of: ifd.littleEndian) { Data($0) })
        func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; withUnsafeBytes(of: &le) { body.append(contentsOf: $0) } }
        put(UInt16(sorted.count))
        for (index, entry) in sorted.enumerated() {
            let (type, count, data) = values[index]
            put(entry.tag); put(type); put(count)
            if let offset = outOfLine[index] {
                put(offset)
            } else {
                var inline = data
                inline.append(contentsOf: [UInt8](repeating: 0, count: 4 - data.count))
                body.append(inline)
            }
        }
        put(UInt32(0))
        return body
    }
}
