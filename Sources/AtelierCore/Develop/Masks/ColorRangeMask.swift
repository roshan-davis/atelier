import CoreImage
import Foundation

/// Color Range masks (AT-068): the color space they are judged in, and picking a color.
enum ColorRangeSpace {
    /// Linear Rec. 2020 (the working space) to linear sRGB.
    private static let rec2020ToSRGB: [SIMD3<Double>] = [
        SIMD3(1.660491, -0.587641, -0.072850),
        SIMD3(-0.124550, 1.132900, -0.008349),
        SIMD3(-0.018151, -0.100579, 1.118730),
    ]
    /// Linear sRGB to Oklab's LMS (Ottosson's M1).
    private static let srgbToLMS: [SIMD3<Double>] = [
        SIMD3(0.4122214708, 0.5363325363, 0.0514459929),
        SIMD3(0.2119034982, 0.6806995451, 0.1073969566),
        SIMD3(0.0883024619, 0.2817188376, 0.6299787005),
    ]

    /// The working space straight to Oklab's LMS, as rows: M1 × (Rec. 2020 to sRGB).
    static let toLMS: [SIMD3<Double>] = srgbToLMS.map { row in
        SIMD3((0..<3).reduce(0.0) { $0 + row[$1] * rec2020ToSRGB[$1].x },
              (0..<3).reduce(0.0) { $0 + row[$1] * rec2020ToSRGB[$1].y },
              (0..<3).reduce(0.0) { $0 + row[$1] * rec2020ToSRGB[$1].z })
    }

    /// A working-space color (linear Rec. 2020) in Oklab, as the Color Range kernel sees it.
    static func oklab(fromWorking c: SIMD3<Double>) -> SIMD3<Double> {
        let lms = toLMS.map { row -> Double in
            let v = (row * c).sum()
            return v < 0 ? -cbrt(-v) : cbrt(v)
        }
        let l: Double = lms[0], m: Double = lms[1], s: Double = lms[2]
        let okL: Double = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let okA: Double = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let okB: Double = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return SIMD3<Double>(okL, okA, okB)
    }

    /// The pick for `box` (top-left fractions of `image`, which starts at the origin): the
    /// average Oklab color there and how much it varies. A box smaller than 5 × 5 pixels is
    /// widened to that around its center.
    static func sample(_ image: CIImage, box: DevelopSettings.MaskRect, context: CIContext) -> DevelopSettings.ColorSample? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        var rect = CGRect(x: extent.minX + CGFloat(box.x) * extent.width,
                          y: extent.minY + (1 - CGFloat(box.y + box.height)) * extent.height,
                          width: CGFloat(box.width) * extent.width, height: CGFloat(box.height) * extent.height)
        if rect.width < 5 || rect.height < 5 {
            rect = CGRect(x: rect.midX - 2.5, y: rect.midY - 2.5, width: 5, height: 5)
        }
        rect = rect.integral.intersection(extent.integral)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        // A large box is read scaled down; the average and spread hardly change.
        let scale = min(1, 256 / max(rect.width, rect.height))
        var source = image.cropped(to: rect)
        if scale < 1 { source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let bounds = source.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(source, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: bounds,
                           format: .RGBAf, colorSpace: nil)
        }
        // Plain loops: the chained map/filter/reduce was too slow for the type checker.
        var labs: [SIMD3<Double>] = []
        labs.reserveCapacity(width * height)
        for i in 0..<(width * height) {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            let lab = oklab(fromWorking: SIMD3<Double>(r, g, b))
            if lab.x.isFinite, lab.y.isFinite, lab.z.isFinite { labs.append(lab) }
        }
        guard !labs.isEmpty else { return nil }
        let count = Double(labs.count)
        var sum = SIMD3<Double>(0, 0, 0)
        for lab in labs { sum += lab }
        let mean = sum / count
        let clickWidth: Double = box.width * Double(extent.width)
        let clickHeight: Double = box.height * Double(extent.height)
        var spread = 0.0
        if clickWidth >= 5 || clickHeight >= 5 {
            var squares = 0.0
            for lab in labs {
                let d = DevelopSettings.ColorSample.distance(lab, mean)
                squares += d * d
            }
            spread = (squares / count).squareRoot()
        }
        return DevelopSettings.ColorSample(box: box, lab: mean, spread: min(spread, 0.15))
    }
}

extension DevelopSession {
    /// A Color Range pick in `box` (top-left fractions of the upright, uncropped photo), taken
    /// from the photo the mask is found on: corrected, with the Remove tool's spots, before tone
    /// and color. Renders, so call it off the main thread.
    public func colorSample(in box: DevelopSettings.MaskRect, settings: DevelopSettings) -> DevelopSettings.ColorSample? {
        guard let image = maskSourceImage(settings) else { return nil }
        return ColorRangeSpace.sample(image, box: box, context: renderContext)
    }
}

extension DevelopSettings.ColorSample {
    /// The pick's color as sRGB (0...1, encoded), for its swatch and its marker on the photo.
    /// It is the photo's color before tone and color sliders, as the mask sees it.
    public var displaySRGB: SIMD3<Double> {
        let l0: Double = self.l + 0.3963377774 * a + 0.2158037573 * b
        let m0: Double = self.l - 0.1055613458 * a - 0.0638541728 * b
        let s0: Double = self.l - 0.0894841775 * a - 1.2914855480 * b
        let l: Double = l0 * l0 * l0, m: Double = m0 * m0 * m0, s: Double = s0 * s0 * s0
        let red: Double = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green: Double = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue: Double = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        let linear = SIMD3<Double>(red, green, blue)
        return SIMD3(DevelopRenderer.srgbEncode(min(max(linear.x, 0), 1)),
                     DevelopRenderer.srgbEncode(min(max(linear.y, 0), 1)),
                     DevelopRenderer.srgbEncode(min(max(linear.z, 0), 1)))
    }
}
