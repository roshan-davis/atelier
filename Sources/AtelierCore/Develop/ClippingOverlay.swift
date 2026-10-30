import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Lightroom's clipping overlay (J, or a click on a histogram triangle): pure white pixels (all
/// three channels at 255) turn red and pure black pixels (all three at 0) turn blue, over the
/// finished render. A saturated color with only one channel at 0 or 255, such as a deep blue
/// sky, still has detail and is left alone; the triangles' color shows those channels. It works
/// on the displayed 8-bit image, so it marks exactly what the histogram's percentages count.
public enum ClippingOverlay {
    public static let highlightColor = CIColor(red: 1, green: 0, blue: 0)
    public static let shadowColor = CIColor(red: 0, green: 0.3, blue: 1)

    /// No color management: the thresholds are on the stored 8-bit values.
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                                     .cacheIntermediates: false])

    public static func apply(to image: CGImage, shadows: Bool, highlights: Bool) -> CGImage? {
        guard shadows || highlights else { return image }
        let source = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        let extent = source.extent
        var result = source
        if highlights {
            // White where even the darkest channel is at 255.
            let darkest = CIFilter.minimumComponent()
            darkest.inputImage = source
            result = paint(highlightColor, over: result, where: darkest.outputImage, above: 254.5 / 255, extent: extent)
        }
        if shadows {
            // White where the brightest channel is above 0; the blue goes everywhere else.
            let brightest = CIFilter.maximumComponent()
            brightest.inputImage = source
            let lifted = threshold(brightest.outputImage, at: 0.5 / 255)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = result
            blend.backgroundImage = CIImage(color: shadowColor).cropped(to: extent)
            blend.maskImage = lifted
            result = blend.outputImage ?? result
        }
        // Keep transparent pixels (a straightened photo's empty corners) transparent.
        let keepAlpha = CIFilter.blendWithAlphaMask()
        keepAlpha.inputImage = result
        keepAlpha.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        keepAlpha.maskImage = source
        guard let output = keepAlpha.outputImage?.cropped(to: extent) else { return nil }
        return context.createCGImage(output, from: extent, format: .RGBA8,
                                     colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func paint(_ color: CIColor, over image: CIImage, where values: CIImage?, above level: Float,
                              extent: CGRect) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(color: color).cropped(to: extent)
        blend.backgroundImage = image
        blend.maskImage = threshold(values, at: level)
        return blend.outputImage ?? image
    }

    /// White above `level`, black at or below it.
    private static func threshold(_ image: CIImage?, at level: Float) -> CIImage? {
        let filter = CIFilter.colorThreshold()
        filter.inputImage = image
        filter.threshold = level
        return filter.outputImage
    }
}
