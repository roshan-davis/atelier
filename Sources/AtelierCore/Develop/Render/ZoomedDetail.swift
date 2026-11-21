import CoreGraphics
import CoreImage
import Foundation
import IOSurface

/// The part of a zoomed photo that is on screen, rendered at the screen's resolution from the
/// full-size photo while a slider drags (Rosh, Nov 21, 2026: "photoshop doesn't do this and
/// still has smooth curve adjustment"). The 2560 px proxy still draws every frame underneath;
/// this frame goes over it so the zoomed photo stays sharp, and costs only the pixels in view
/// (about a quarter of a 24 MP photo at 100% on a laptop screen) instead of the whole photo,
/// which took 55-170 ms a frame (Rosh's traces, Nov 20, 2026) and is why the full-size render
/// waits for the drag to rest (AT-039 D4).
public enum ZoomedDetail {
    /// Where in a rendered image the region `visible` (0...1 across and down from the top-left,
    /// as `ZoomViewport.visible`) lies, in Core Image's coordinates (origin bottom-left), and the
    /// scale that brings it to `pixels` (never above 1: past 100% the screen magnifies it).
    public struct Region: Equatable, Sendable {
        public let source: CGRect
        public let scale: CGFloat
        /// The rendered frame's size in pixels.
        public let size: CGSize
        /// The part of the image the frame shows, 0...1 from the top-left: `source` (whole
        /// pixels) in the terms of `visible`, which it rounds out by under a pixel. Where the frame
        /// must be placed so its pixels sit exactly on the image's.
        public let shown: CGRect
    }

    public static func region(of extent: CGRect, visible: CGRect, pixels: CGSize) -> Region? {
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite,
              visible.width > 0, visible.height > 0, pixels.width >= 1, pixels.height >= 1 else { return nil }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let shown = visible.intersection(unit)
        guard !shown.isNull, shown.width > 0, shown.height > 0 else { return nil }
        let source = CGRect(x: extent.minX + shown.minX * extent.width,
                            y: extent.minY + (1 - shown.maxY) * extent.height,
                            width: shown.width * extent.width,
                            height: shown.height * extent.height)
            .integral.intersection(extent)
        guard !source.isNull, source.width >= 1, source.height >= 1 else { return nil }
        let scale = min(1, pixels.width / source.width, pixels.height / source.height)
        let size = CGSize(width: max(1, (source.width * scale).rounded()),
                          height: max(1, (source.height * scale).rounded()))
        let shownRect = CGRect(x: (source.minX - extent.minX) / extent.width,
                               y: 1 - (source.maxY - extent.minY) / extent.height,
                               width: source.width / extent.width, height: source.height / extent.height)
        return Region(source: source, scale: scale, size: size, shown: shownRect)
    }

    /// Whether an image `imageWidth` pixels wide already has as many pixels in the visible part
    /// as the screen shows there (within 5%), so a detail frame would add nothing.
    public static func isSharpEnough(imageWidth: CGFloat, visibleWidth: CGFloat, screenPixels: CGFloat) -> Bool {
        imageWidth * visibleWidth >= screenPixels * 0.95
    }
}

extension DevelopSession {
    /// Renders the visible region of the photo with `settings` (`ZoomedDetail.region`) into a
    /// free surface from `surfaces`, on the calling thread. Only the region's pixels are
    /// computed: Core Image works out each step's region of interest from the crop. Nil when the
    /// photo can't be rendered, the region is empty or no surface is free.
    public func renderZoomedDetail(_ settings: DevelopSettings, visible: CGRect, pixels: CGSize,
                                   shadowClipping: Bool = false, highlightClipping: Bool = false,
                                   surfaces: DisplaySurfaces) -> IOSurface? {
        renderZoomedRegion(settings, visible: visible, pixels: pixels, shadowClipping: shadowClipping,
                           highlightClipping: highlightClipping, surfaces: surfaces)?.surface
    }

    /// `renderZoomedDetail`, with the part of the photo the frame actually shows (`Region.shown`,
    /// 0...1 from the top-left), so it can be placed exactly over the photo.
    public func renderZoomedRegion(_ settings: DevelopSettings, visible: CGRect, pixels: CGSize,
                                   shadowClipping: Bool = false, highlightClipping: Bool = false,
                                   surfaces: DisplaySurfaces) -> (surface: IOSurface, shown: CGRect)? {
        guard var image = image(with: settings),
              let region = ZoomedDetail.region(of: image.extent, visible: visible, pixels: pixels) else { return nil }
        if shadowClipping || highlightClipping {
            image = ClippingOverlay.apply(to: image, shadows: shadowClipping, highlights: highlightClipping,
                                          shownIn: surfaces.colorSpace)
        }
        // A few pixels round the region go along, so Lanczos has real neighbours at its edges.
        let margin = region.scale < 0.999 ? region.source.insetBy(dx: -4, dy: -4).intersection(image.extent) : region.source
        var detail = image.cropped(to: margin)
            .transformed(by: CGAffineTransform(translationX: -region.source.minX, y: -region.source.minY))
        if region.scale < 0.999 {
            detail = detail.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: region.scale,
                                                                                   kCIInputAspectRatioKey: 1])
        }
        detail = detail.cropped(to: CGRect(origin: .zero, size: region.size))
        guard let surface = DevelopRenderer.shared.render(detail, into: surfaces, onPoolFull: nil) else { return nil }
        return (surface, region.shown)
    }
}
