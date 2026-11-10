import CoreImage
import Foundation
import IOSurface

/// Builds Core Image's programs for the slider changes a photo is likely to get next, before the
/// first drag needs them (AT-039 D3a).
///
/// Each Develop tool that is at zero is left out of the render, so the first tick that moves one
/// off zero gives Core Image a pipeline it has never seen, and it compiles that before drawing:
/// AT-038's Frame Diagnostics measured 657 ms to 1.4 s for the first Highlights or Contrast frame
/// on a Z6 NEF, held on the photo while the knob moves. LightCraft compiles all of its kernels
/// at launch. Here, when a photo opens, a tiny stand-in image goes through the photo's own
/// settings with each idle tool turned on in turn, on a background queue, so the drag finds the
/// programs ready. Nothing is shown and the photo's renders are unchanged.
extension DevelopRenderer {
    /// One render per idle tool, on top of `settings` (the open photo's), at the live proxy's
    /// `scale` so blur radii, and with them Core Image's programs, match the drag's.
    /// `isCurrent` is asked between renders; once it says no (another photo opened), it stops.
    /// Returns how many renders ran.
    @discardableResult
    public func warmUp(_ settings: DevelopSettings, scale: Double, isCurrent: () -> Bool = { true }) -> Int {
        guard let input = Self.warmUpInput,
              let surface = DisplaySurfaces.make(width: Self.warmUpSize.width, height: Self.warmUpSize.height,
                                                 colorSpace: Self.displaySpace) else { return 0 }
        var count = 0
        for variant in Self.warmUpVariants(settings) {
            guard isCurrent() else { break }
            let image = Self.applyAdjustments(variant.applyingPanelSwitches(), to: input, scale: scale, cacheStages: true)
            let destination = CIRenderDestination(ioSurface: surface)
            destination.colorSpace = Self.displaySpace
            destination.isFlipped = Self.surfaceNeedsFlip
            guard let task = try? context.startTask(toRender: image, from: input.extent, to: destination, at: .zero) else { continue }
            _ = try? task.waitUntilCompleted()
            count += 1
        }
        return count
    }

    /// The photo's settings without its masks (they need the photo itself), then once for each
    /// tool that is off, with that tool on. Tools that are already on are in the first one.
    static func warmUpVariants(_ settings: DevelopSettings) -> [DevelopSettings] {
        var base = settings
        base.masks = []
        var variants = [base]
        func probe(_ change: (inout DevelopSettings) -> Void) {
            var variant = base
            change(&variant)
            if variant != base { variants.append(variant) }
        }
        func on(_ parameter: DevelopSettings.Parameter, _ value: Double) {
            probe { if $0[parameter] == 0 { $0[parameter] = value } }
        }
        // Basic: Highlights and Shadows share one step; Contrast, Whites and Blacks one curve.
        on(.highlights, -30)
        on(.contrast, 20)
        on(.texture, 20)
        on(.clarity, 20)
        on(.dehaze, 20)
        on(.vibrance, 20)
        on(.saturation, 20)
        // HSL / Color, Point Color, B&W Mix and Color Grading share one color cube.
        on(.satRed, 20)
        // Detail.
        on(.sharpening, 40)
        probe {
            if $0[.sharpenMasking] == 0 { $0[.sharpenMasking] = 30 }
            if $0[.sharpening] == 0 { $0[.sharpening] = 40 }
        }
        on(.luminanceNoise, 20)
        on(.colorNoise, 25)
        // Effects.
        on(.glowAmount, 20)
        on(.vignette, -20)
        on(.grain, 20)
        return variants
    }

    static let warmUpSize = (width: 64, height: 48)

    /// A small gradient in the working space, made once: a plain bitmap, so it enters the
    /// pipeline the way the cached decode does (as an image to sample, not a generator).
    static let warmUpInput: CIImage? = {
        let (width, height) = warmUpSize
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let u = Float(x) / Float(width - 1), v = Float(y) / Float(height - 1)
                pixels[i] = u * u
                pixels[i + 1] = v
                pixels[i + 2] = (1 - u) * v
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: workingSpace)
    }()
}
