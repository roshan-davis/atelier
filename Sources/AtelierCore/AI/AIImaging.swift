import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// One brush stroke on the photo. Points are fractions of the image (0...1, top-left origin);
/// the radius is a fraction of the image width.
public struct BrushStroke: Codable, Hashable, Sendable {
    public var points: [CGPoint]
    public var radius: Double
    /// Erasing strokes take paint away.
    public var erases: Bool

    public init(points: [CGPoint], radius: Double, erases: Bool = false) {
        self.points = points
        self.radius = radius
        self.erases = erases
    }
}

public enum AIImaging {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let gray = CGColorSpaceCreateDeviceGray()
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Paints strokes white on black at `width` x `height`.
    public static func mask(from strokes: [BrushStroke], width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip so stroke points read top-down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes where !stroke.points.isEmpty {
            let shade: CGFloat = stroke.erases ? 0 : 1
            let lineWidth = CGFloat(stroke.radius * 2) * CGFloat(width)
            let points = stroke.points.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
            context.setStrokeColor(gray: shade, alpha: 1)
            context.setFillColor(gray: shade, alpha: 1)
            context.setLineWidth(lineWidth)
            if points.count == 1 {
                let p = points[0]
                context.fillEllipse(in: CGRect(x: p.x - lineWidth / 2, y: p.y - lineWidth / 2, width: lineWidth, height: lineWidth))
            } else {
                context.addLines(between: points)
                context.strokePath()
            }
        }
        return context.makeImage()
    }

    /// The bounding box of the white part of a mask, in pixels with a top-left origin.
    public static func bounds(of mask: CGImage) -> CGRect? {
        let width = mask.width, height = mask.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // Row 0 of a bitmap context's memory is the top of the image.
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The area to send for an object removal: the painted box with surroundings for context,
    /// kept inside the image.
    public static func contextRegion(around box: CGRect, imageSize: CGSize) -> CGRect {
        let pad = max(max(box.width, box.height) * 0.75, 96)
        var region = box.insetBy(dx: -pad, dy: -pad)
        // Not too thin a strip, so the model sees enough.
        let minSide = min(max(region.width, region.height), min(imageSize.width, imageSize.height))
        if region.width < minSide { region = region.insetBy(dx: -(minSide - region.width) / 2, dy: 0) }
        if region.height < minSide { region = region.insetBy(dx: 0, dy: -(minSide - region.height) / 2) }
        return region.intersection(CGRect(origin: .zero, size: imageSize)).integral
    }

    /// Generation size for a region: long edge `longEdge`, both sides multiples of 8.
    public static func workSize(for size: CGSize, longEdge: Int) -> CGSize {
        let scale = Double(longEdge) / Double(max(size.width, size.height))
        func round8(_ value: Double) -> Int { max(64, Int((value / 8).rounded()) * 8) }
        return CGSize(width: round8(size.width * scale), height: round8(size.height * scale))
    }

    /// Crops `image` to `region` (top-left origin) and scales it to `size`.
    public static func crop(_ image: CGImage, to region: CGRect, scaledTo size: CGSize) -> CGImage? {
        guard let cropped = image.cropping(to: region) else { return nil }
        return resize(cropped, to: size)
    }

    public static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let isGray = image.colorSpace?.model == .monochrome
        let space = isGray ? gray : (image.colorSpace ?? sRGB)
        let info = isGray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    /// Puts `result` (generated for `region`) back into `base`, only where `mask` is white,
    /// with edges feathered by `feather` pixels after growing the mask by `grow`. `mask` is base-sized.
    public static func composite(_ result: CGImage, into base: CGImage, region: CGRect, mask: CGImage,
                                 feather: Double, grow: Double = 0) -> CGImage? {
        let baseImage = CIImage(cgImage: base)
        let extent = baseImage.extent
        // Core Image's origin is bottom-left.
        let y = extent.height - region.maxY
        let placed = CIImage(cgImage: result)
            .transformed(by: CGAffineTransform(scaleX: region.width / CGFloat(result.width),
                                               y: region.height / CGFloat(result.height)))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: y))
        var maskImage = CIImage(cgImage: mask)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(mask.width),
                                               y: extent.height / CGFloat(mask.height)))
        if grow > 0 {
            maskImage = maskImage.clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]).cropped(to: extent)
        }
        if feather > 0 {
            maskImage = maskImage.clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: extent)
        }
        // Nothing outside the generated region changes.
        let regionMask = CIImage(color: .white).cropped(to: CGRect(x: region.minX, y: y, width: region.width, height: region.height))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        let limited = maskImage.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: regionMask])
        let blend = CIFilter.blendWithMask()
        blend.inputImage = placed
        blend.backgroundImage = baseImage
        blend.maskImage = limited
        guard let output = blend.outputImage?.cropped(to: extent) else { return nil }
        return context.createCGImage(output, from: extent, format: .RGBA16, colorSpace: base.colorSpace ?? sRGB)
    }

    /// White where Vision finds the photo's subject (people, animals, objects in front).
    public static func subjectMask(for image: CGImage) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let mask = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(mask, from: mask.extent, format: .L8, colorSpace: gray)
    }

    public static func inverted(_ mask: CGImage) -> CGImage? {
        let image = CIImage(cgImage: mask).applyingFilter("CIColorInvert")
        return context.createCGImage(image, from: image.extent, format: .L8, colorSpace: gray)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A gray mask as RGB, which ComfyUI's LoadImageMask reads by its red channel.
    public static func rgbPNG(fromMask mask: CGImage) -> Data? {
        guard let context = CGContext(data: nil, width: mask.width, height: mask.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
        return context.makeImage().flatMap(pngData)
    }

    public static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
