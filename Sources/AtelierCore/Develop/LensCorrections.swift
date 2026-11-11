import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

extension DevelopRenderer {
    /// Pipeline step 1's lens corrections and Transform, on a decoded photo whose extent starts
    /// at the origin: chromatic aberration (`lateral`, nil or none for off), Defringe, lens
    /// vignetting, then distortion, Upright and the Transform sliders. Returns `image` itself
    /// when none of them applies. `scale` is the render's size relative to the full photo.
    ///
    /// Shared by the session (on its kept decode) and the warm-up (on a stand-in), so both build
    /// the same Core Image programs.
    static func applyLensCorrections(_ settings: DevelopSettings, to decoded: CIImage, scale: Double,
                                     lateral: LateralCA?, focalLength35: Double,
                                     defringeView: Defringe.View = .photo) -> CIImage {
        var image = decoded
        let extent = decoded.extent
        if let lateral { image = lateral.apply(to: image) }
        image = Defringe.apply(image, settings: settings, scale: scale, view: defringeView)
        // Lens vignetting, around the uncropped photo's center, before the warp moves it.
        if settings[.lensVignette] != 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = image
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            let diagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2
            filter.radius = Float(diagonal * (0.35 + settings[.lensVignetteMidpoint] / 100 * 0.6))
            filter.falloff = 0.6
            filter.intensity = Float(-settings[.lensVignette] / 100)
            image = filter.outputImage?.cropped(to: extent) ?? image
        }
        if settings.hasLensGeometry {
            image = LensGeometry(settings: settings, size: extent.size, focalLength35: focalLength35).apply(to: image)
        }
        return image
    }
}
