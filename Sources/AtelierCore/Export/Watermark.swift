import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO

/// A text or logo drawn on exported photos. Size and inset are fractions of the photo, so the
/// mark sits the same on a 2048 px website JPEG, a full-size TIFF and the dialog's preview.
public struct ExportWatermark: Codable, Hashable, Sendable {
    public enum Style: String, CaseIterable, Codable, Sendable {
        case text, image

        public var label: String {
            switch self {
            case .text: return "Text"
            case .image: return "Image"
            }
        }
    }

    public enum TextColor: String, CaseIterable, Codable, Sendable {
        case white, black

        public var label: String {
            switch self {
            case .white: return "White"
            case .black: return "Black"
            }
        }
    }

    /// Where the mark sits, in reading order: top row, middle row, bottom row.
    public enum Anchor: String, CaseIterable, Codable, Sendable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

        public var label: String {
            switch self {
            case .topLeft: return "Top Left"
            case .top: return "Top"
            case .topRight: return "Top Right"
            case .left: return "Left"
            case .center: return "Center"
            case .right: return "Right"
            case .bottomLeft: return "Bottom Left"
            case .bottom: return "Bottom"
            case .bottomRight: return "Bottom Right"
            }
        }

        /// -1 left, 0 center, 1 right.
        var column: Int { [-1, 0, 1][Self.allCases.firstIndex(of: self)! % 3] }
        /// 1 top, 0 middle, -1 bottom.
        var row: Int { [1, 0, -1][Self.allCases.firstIndex(of: self)! / 3] }
    }

    public var style: Style = .text
    public var text: String
    public var textColor: TextColor = .white
    /// A PNG (with transparency) or other image file, for the Image style.
    public var imagePath: String?
    /// 0...1.
    public var opacity: Double = 0.7
    /// The mark's width as a fraction of the photo's width.
    public var size: Double = 0.2
    public var anchor: Anchor = .bottomRight
    /// The gap to the photo's edges as a fraction of its short edge.
    public var inset: Double = 0.03
    public var shadow: Bool = true

    public init(text: String) {
        self.text = text
    }

    public static let sizeRange: ClosedRange<Double> = 0.03...0.9
    public static let insetRange: ClosedRange<Double> = 0...0.2

    /// "© 2026 Name", for a new text watermark.
    public static func copyright(owner: String, year: Int = Calendar.current.component(.year, from: Date())) -> ExportWatermark {
        ExportWatermark(text: owner.isEmpty ? "© \(year)" : "© \(year) \(owner)")
    }

    /// True when there is something to draw: text that isn't blank, or a chosen image.
    public var hasContent: Bool {
        switch style {
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image: return imagePath != nil
        }
    }
}

public enum Watermark {
    /// Draws the watermark on `image`; the result keeps `image`'s extent. Returns `image`
    /// unchanged when there's nothing to draw or the logo file can't be read.
    public static func apply(_ watermark: ExportWatermark?, to image: CIImage) -> CIImage {
        guard let watermark, watermark.hasContent, watermark.opacity > 0 else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, let rendered = render(watermark, photo: extent.size) else { return image }

        var mark = CIImage(cgImage: rendered.image)
        if watermark.opacity < 1 {
            let fade = CIFilter.colorMatrix()
            fade.inputImage = mark
            fade.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(1, watermark.opacity)))
            mark = fade.outputImage ?? mark
        }
        let position = origin(markSize: rendered.contentSize, in: extent, anchor: watermark.anchor, inset: watermark.inset)
        mark = mark.transformed(by: CGAffineTransform(translationX: position.x - rendered.padding,
                                                      y: position.y - rendered.padding))
        return mark.composited(over: image).cropped(to: extent)
    }

    /// The bottom-left corner of a mark of `markSize` placed at `anchor` in `extent`
    /// (Core Image coordinates: y grows upward). `inset` is a fraction of the short edge.
    public static func origin(markSize: CGSize, in extent: CGRect, anchor: ExportWatermark.Anchor, inset: Double) -> CGPoint {
        let gap = CGFloat(inset) * min(extent.width, extent.height)
        let x: CGFloat
        switch anchor.column {
        case -1: x = extent.minX + gap
        case 1: x = extent.maxX - gap - markSize.width
        default: x = extent.midX - markSize.width / 2
        }
        let y: CGFloat
        switch anchor.row {
        case 1: y = extent.maxY - gap - markSize.height
        case -1: y = extent.minY + gap
        default: y = extent.midY - markSize.height / 2
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// The mark's size in pixels for a photo of `photo` size and content of `aspect` (width / height):
    /// `size` of the photo's width, made smaller if it would not fit inside the inset.
    public static func markSize(_ watermark: ExportWatermark, aspect: CGFloat, photo: CGSize) -> CGSize {
        let gap = CGFloat(watermark.inset) * min(photo.width, photo.height)
        let fraction = CGFloat(min(max(watermark.size, ExportWatermark.sizeRange.lowerBound), ExportWatermark.sizeRange.upperBound))
        var width = photo.width * fraction
        let maxWidth = max(1, photo.width - 2 * gap)
        let maxHeight = max(1, photo.height - 2 * gap)
        width = min(width, maxWidth, maxHeight * aspect)
        return CGSize(width: max(1, width), height: max(1, width / aspect))
    }

    struct Rendered {
        var image: CGImage
        /// The text or logo without the room left around it for the shadow.
        var contentSize: CGSize
        var padding: CGFloat
    }

    /// Draws the text or logo at its final pixel size, so it stays crisp at any export size.
    static func render(_ watermark: ExportWatermark, photo: CGSize) -> Rendered? {
        switch watermark.style {
        case .text:
            let text = watermark.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Measure at 100 pt, then set the size that makes the line the wanted width.
            let probe = line(text, fontSize: 100, color: .white)
            guard probe.width > 0, probe.height > 0 else { return nil }
            let size = markSize(watermark, aspect: probe.width / probe.height, photo: photo)
            var fontSize = 100 * size.width / probe.width
            let color: CGColor = watermark.textColor == .white
                ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            var sized = line(text, fontSize: fontSize, color: color)
            // The system font's tracking and optical size change with point size, so width isn't
            // proportional to size (a 2048 px export and the dialog's preview would differ).
            // Correct until the line is the wanted width.
            for _ in 0..<4 where sized.width > 0 && abs(sized.width - size.width) > 0.25 {
                fontSize *= size.width / sized.width
                sized = line(text, fontSize: fontSize, color: color)
            }
            let contentSize = CGSize(width: ceil(sized.width), height: ceil(sized.height))
            return draw(contentSize: contentSize, shadow: watermark.shadow) { context, origin in
                context.textPosition = CGPoint(x: origin.x, y: origin.y + sized.descent)
                CTLineDraw(sized.line, context)
            }
        case .image:
            guard let path = watermark.imagePath,
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let logo = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  logo.width > 0, logo.height > 0 else { return nil }
            let size = markSize(watermark, aspect: CGFloat(logo.width) / CGFloat(logo.height), photo: photo)
            let contentSize = CGSize(width: ceil(size.width), height: ceil(size.height))
            return draw(contentSize: contentSize, shadow: watermark.shadow) { context, origin in
                context.interpolationQuality = .high
                context.draw(logo, in: CGRect(origin: origin, size: contentSize))
            }
        }
    }

    private struct Line {
        var line: CTLine
        var width: CGFloat
        var height: CGFloat
        var descent: CGFloat
    }

    private static func line(_ text: String, fontSize: CGFloat, color: CGColor) -> Line {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return Line(line: line, width: width, height: ascent + descent, descent: descent)
    }

    /// A transparent sRGB canvas with room for the shadow around `contentSize`.
    private static func draw(contentSize: CGSize, shadow: Bool,
                             _ body: (CGContext, CGPoint) -> Void) -> Rendered? {
        let blur = max(1, min(contentSize.width, contentSize.height) * 0.06)
        let padding = shadow ? ceil(blur * 2.5) : 0
        let width = Int(contentSize.width + 2 * padding), height = Int(contentSize.height + 2 * padding)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if shadow {
            context.setShadow(offset: CGSize(width: blur * 0.4, height: -blur * 0.4), blur: blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        }
        body(context, CGPoint(x: padding, y: padding))
        guard let image = context.makeImage() else { return nil }
        return Rendered(image: image, contentSize: contentSize, padding: padding)
    }
}
