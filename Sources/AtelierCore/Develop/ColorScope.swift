import CoreGraphics
import Foundation

/// Where a rendered photo's colors sit on the Color Grading wheels, like a small vectorscope:
/// each sample's angle is the wheel hue that tints toward its color and its distance from the
/// center grows with its chroma. The wheels draw the samples of their own tonal range, so a cast
/// shows as a cluster and the dot can be aimed at it, or opposite it to cancel it.
public struct ColorScope: Sendable, Hashable {
    public struct Sample: Sendable, Hashable {
        /// Wheel hue in degrees, counterclockwise from 3 o'clock as the wheels draw it.
        public var hue: Double
        /// Distance from the wheel's center, 0...1.
        public var radius: Double
        /// sRGB-encoded luma, which decides how much each wheel's range covers the sample.
        public var luma: Double
    }

    public var samples: [Sample]

    /// Oklab chroma drawn at the wheel's rim; few photo colors go further.
    static let rimChroma = 0.3

    /// Samples a small copy of the image, so this is cheap enough to run after every render.
    /// Near-grays are left out so the center stays readable; so are transparent pixels.
    public init?(image: CGImage, sampleSize: Int = 48) {
        let scale = min(1, Double(sampleSize) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var samples: [Sample] = []
        samples.reserveCapacity(width * height)
        for i in 0..<(width * height) {
            let alpha = Double(pixels[i * 4 + 3])
            guard alpha > 0 else { continue }
            let color: RGB = (Double(pixels[i * 4]) / alpha, Double(pixels[i * 4 + 1]) / alpha, Double(pixels[i * 4 + 2]) / alpha)
            let lab = Oklab.fromEncoded(color)
            let ab = SIMD2(lab.y, lab.z)
            let chroma = (ab * ab).sum().squareRoot()
            guard chroma > 0.012 else { continue }
            // Square root spreads the many low-chroma colors of a photo away from the center.
            samples.append(Sample(hue: ColorGrade.hue(towards: ab), radius: min(1, (chroma / Self.rimChroma).squareRoot()),
                                  luma: luma(color)))
        }
        self.samples = samples
    }
}
