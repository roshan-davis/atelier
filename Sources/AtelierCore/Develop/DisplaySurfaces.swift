import CoreGraphics
import CoreImage
import Foundation
import IOSurface

/// GPU surfaces the Develop photo view shows directly, so a slider drag's frames go from
/// Core Image to the screen without being read back to the CPU and uploaded again (the way
/// LightCraft draws its renders; see reports/develop-preview-vs-lightcraft-2026-11-10.md).
///
/// Core Image renders a frame into a surface nobody is showing; the photo view's layer then
/// shows that surface as its contents. A surface goes back to the pool when another frame or
/// image replaces it, and is reused only once the window server has let go of it too
/// (`isInUse`), so a frame is never drawn into while it is on screen.
public final class DisplaySurfaces: @unchecked Sendable {
    /// Display P3, like every other Develop render.
    public let colorSpace: CGColorSpace
    /// At most this many surfaces of one size exist; with all of them in use a frame is
    /// rendered the ordinary way instead.
    public static let limit = 4

    private let lock = NSLock()
    private var free: [IOSurface] = []
    private var width = 0
    private var height = 0
    /// Surfaces of the current size made so far, free or out.
    private var made = 0

    public init(colorSpace: CGColorSpace = DevelopRenderer.displaySpace) {
        self.colorSpace = colorSpace
    }

    /// A surface of `width` × `height` that isn't on screen, or nil when all of them are.
    func checkOut(width: Int, height: Int, onPoolFull: (() -> Void)? = nil) -> IOSurface? {
        lock.lock()
        var full = false
        defer {
            lock.unlock()
            if full { onPoolFull?() }
        }
        if width != self.width || height != self.height {
            // A new size (another photo, a crop): surfaces of the old size are let go as they
            // come back.
            free.removeAll()
            made = 0
            self.width = width
            self.height = height
        }
        if let index = free.firstIndex(where: { !$0.isInUse }) {
            return free.remove(at: index)
        }
        guard made < Self.limit else {
            full = true
            return nil
        }
        guard let surface = Self.make(width: width, height: height, colorSpace: colorSpace) else { return nil }
        made += 1
        return surface
    }

    /// Gives `surface` back once it is off screen, or was never shown.
    public func checkIn(_ surface: IOSurface) {
        lock.lock()
        defer { lock.unlock() }
        guard surface.width == width, surface.height == height,
              !free.contains(where: { $0 === surface }) else { return }
        free.append(surface)
    }

    static func make(width: Int, height: Int, colorSpace: CGColorSpace?) -> IOSurface? {
        guard width > 0, height > 0 else { return nil }
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            // 'BGRA': 8-bit, premultiplied alpha first in little-endian order, the format Core
            // Animation shows directly.
            .pixelFormat: UInt32(0x4247_5241),
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        // Tag the surface so the window server color-matches it from Display P3, as it does a
        // CGImage tagged Display P3; untagged it would be shown as the display's own space.
        if let colorSpace {
            if let name = colorSpace.name {
                IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, name)
            } else if let icc = colorSpace.copyICCData() {
                IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, icc)
            }
        }
        return surface
    }
}

extension DevelopRenderer {
    /// Copies stored display values unchanged (no color management), for reading a surface back
    /// small for the histogram.
    static let passthroughContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                                        .cacheIntermediates: false])

    /// Whether Core Image writes an IOSurface bottom row first, found once by rendering a
    /// two-row image (red on top) and reading the surface's first row. The answer sets
    /// `CIRenderDestination.isFlipped`, so the photo is never shown upside down whichever way
    /// this macOS version does it.
    static let surfaceNeedsFlip: Bool = {
        let renderer = DevelopRenderer.shared
        let top = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 1, width: 2, height: 1))
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 1))
        let probe = top.composited(over: bottom)
        guard let surface = DisplaySurfaces.make(width: 2, height: 2, colorSpace: nil) else { return false }
        let destination = CIRenderDestination(ioSurface: surface)
        destination.colorSpace = DevelopRenderer.sRGB
        do {
            let task = try renderer.context.startTask(toRender: probe, from: probe.extent, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        } catch {
            return false
        }
        _ = surface.lock(options: .readOnly, seed: nil)
        defer { _ = surface.unlock(options: .readOnly, seed: nil) }
        // BGRA: byte 0 is blue, byte 2 red.
        let first = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        return first[0] > first[2]
    }()

    /// Renders `image` into a free surface from `surfaces`, on the calling thread, and returns
    /// it once the GPU has finished; nil when no surface is free or the render failed.
    func render(_ image: CIImage, into surfaces: DisplaySurfaces, onPoolFull: (() -> Void)?) -> IOSurface? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite,
              let surface = surfaces.checkOut(width: Int(extent.width), height: Int(extent.height), onPoolFull: onPoolFull) else { return nil }
        let destination = CIRenderDestination(ioSurface: surface)
        destination.colorSpace = surfaces.colorSpace
        destination.isFlipped = Self.surfaceNeedsFlip
        do {
            let task = try context.startTask(toRender: image, from: extent, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
            return surface
        } catch {
            surfaces.checkIn(surface)
            return nil
        }
    }

    /// The surface's stored values, at most `sampleSize` pixels long, for the histogram and
    /// color scope (they work on the displayed values, as from an ordinary render).
    func sample(of surface: IOSurface, colorSpace: CGColorSpace, sampleSize: Int) -> CGImage? {
        var image = CIImage(ioSurface: surface, options: [.colorSpace: NSNull()])
        let extent = image.extent
        let factor = min(1, CGFloat(sampleSize) / max(1, max(extent.width, extent.height)))
        if factor < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor,
                                                                                 kCIInputAspectRatioKey: 1])
        }
        return Self.passthroughContext.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                     colorSpace: colorSpace, deferred: false)
    }
}

extension DevelopSession {
    /// A live frame for the Develop photo view: drawn straight into a GPU surface the view shows,
    /// with `plain`, a small copy without the clipping overlay for the histogram. Renders the same
    /// image as `renderForDisplay`; only where the pixels land differs. Nil when no surface is
    /// free or the render failed; render the ordinary way then.
    public func renderToSurface(_ settings: DevelopSettings, cropping: Bool = true, overlay: UUID? = nil,
                                preview: SliderPreview? = nil, shadowClipping: Bool = false,
                                highlightClipping: Bool = false, surfaces: DisplaySurfaces,
                                sampleSize: Int = Histogram.sampleSize, onPoolFull: (() -> Void)? = nil) -> (surface: IOSurface, plain: CGImage?)? {
        guard var image = image(with: settings, cropping: cropping, overlay: overlay, preview: preview) else { return nil }
        let renderer = DevelopRenderer.shared
        guard shadowClipping || highlightClipping else {
            guard let surface = renderer.render(image, into: surfaces, onPoolFull: onPoolFull) else { return nil }
            let sample = RenderSignposts.measure("Live frame sample") {
                renderer.sample(of: surface, colorSpace: surfaces.colorSpace, sampleSize: sampleSize)
            }
            return (surface, sample)
        }
        // As in `renderForDisplay`: the histogram is counted from the photo without the overlay,
        // made from the render Core Image just cached.
        image = image.insertingIntermediate(cache: true)
        let painted = ClippingOverlay.apply(to: image, shadows: shadowClipping, highlights: highlightClipping,
                                            shownIn: surfaces.colorSpace)
        guard let surface = renderer.render(painted, into: surfaces, onPoolFull: onPoolFull) else { return nil }
        let extent = image.extent
        let factor = min(1, CGFloat(sampleSize) / max(1, max(extent.width, extent.height)))
        var small = image
        if factor < 1 {
            small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor,
                                                                                 kCIInputAspectRatioKey: 1])
        }
        let sample = RenderSignposts.measure("Live frame sample") {
            renderer.cgImage(small, colorSpace: surfaces.colorSpace)
        }
        return (surface, sample)
    }
}
