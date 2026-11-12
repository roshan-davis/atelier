import Foundation
import CoreImage
import ImageIO

/// Apple decoder and profiled TIFF boundary, kept outside the pure pixel engine.
public final class HDRImageIO {
    public static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [.workingColorSpace: linear,
                                              .workingFormat: CIFormat.RGBAf,
                                              .cacheIntermediates: false])
    public init() {}

    public static func dimensions(_ url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw HDRError.unsupportedImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height.doubleValue, height: width.doubleValue)
            : CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    public func decode(_ url: URL, longEdge: Int? = nil) throws -> HDRImage {
        let decoded: CIImage
        let rawExtensions = ["nef", "dng", "arw", "cr2", "cr3", "raf", "orf", "rw2", "pef"]
        if rawExtensions.contains(url.pathExtension.lowercased()) {
            guard let raw = CIRAWFilter(imageURL: url) else { throw HDRError.unsupportedImage }
            raw.boostAmount = 0; raw.baselineExposure = 0; raw.shadowBias = 0
            raw.isGamutMappingEnabled = false
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = false }
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
            if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
            if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
            if raw.isContrastSupported { raw.contrastAmount = 0 }
            if raw.isDetailSupported { raw.detailAmount = 0 }
            raw.extendedDynamicRangeAmount = 2
            if let longEdge {
                raw.scaleFactor = Float(min(1, Double(longEdge) / max(raw.nativeSize.width, raw.nativeSize.height)))
            }
            guard let output = raw.outputImage else { throw HDRError.unsupportedImage }
            decoded = output
        } else {
            guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw HDRError.unsupportedImage
            }
            if let longEdge {
                let scale = min(1, Double(longEdge) / max(image.extent.width, image.extent.height))
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            decoded = image
        }
        let bounds = CGRect(x: 0, y: 0, width: floor(decoded.extent.width), height: floor(decoded.extent.height))
        let image = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX,
                                                               y: -decoded.extent.minY))
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0, width <= 100_000, height <= 100_000 else { throw HDRError.invalidImage }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: bounds,
                       format: .RGBAf, colorSpace: Self.linear)
        var rgb = [Float](repeating: 0, count: width * height * 3)
        rgba.withUnsafeBufferPointer { rgba in
            rgb.withUnsafeMutableBufferPointer { rgb in
                HDRToneMapper.rows(height) { y in
                    for i in (y * width)..<((y + 1) * width) {
                        rgb[i*3] = rgba[i*4]; rgb[i*3+1] = rgba[i*4+1]; rgb[i*3+2] = rgba[i*4+2]
                    }
                }
            }
        }
        return try HDRImage(width: width, height: height, rgb: rgb)
    }

    /// The same RGBA float bitmap as before, filled row bands at a time on all cores rather
    /// than appended pixel by pixel (it is made for every preview while a slider moves).
    public func ciImage(_ image: HDRImage) -> CIImage { Self.linearImage(image) }

    /// `image` as a linear sRGB Core Image image, alpha 1 (`ciImage`; the GPU preview's input too).
    public static func linearImage(_ image: HDRImage) -> CIImage {
        let width = image.width
        var rgba = [Float](repeating: 1, count: image.width * image.height * 4)
        image.rgb.withUnsafeBufferPointer { rgb in
            rgba.withUnsafeMutableBufferPointer { rgba in
                HDRToneMapper.rows(image.height) { y in
                    for i in (y * width)..<((y + 1) * width) {
                        rgba[i*4] = rgb[i*3]; rgba[i*4+1] = rgb[i*3+1]; rgba[i*4+2] = rgb[i*3+2]
                    }
                }
            }
        }
        return rgba.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: image.width * 16,
                    size: CGSize(width: image.width, height: image.height), format: .RGBAf, colorSpace: Self.linear)
        }
    }

    public func preview(_ image: HDRImage) throws -> CGImage {
        guard let result = context.createCGImage(ciImage(image), from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw HDRError.unsupportedImage
        }
        return result
    }

    public func writeTIFF(_ image: HDRImage, to url: URL) throws {
        try context.writeTIFFRepresentation(of: ciImage(image), to: url, format: .RGBA16,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        try Self.validateTIFF(url, width: image.width, height: image.height)
    }

    public static func validateTIFF(_ url: URL, width: Int, height: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cg.width == width, cg.height == height, cg.bitsPerComponent == 16,
              cg.colorSpace?.copyICCData() != nil else { throw HDRError.invalidImage }
    }
}
