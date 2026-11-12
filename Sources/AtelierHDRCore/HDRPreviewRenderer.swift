import CoreGraphics
import CoreImage
import Foundation
import IOSurface

/// The tone mapper's per-pixel pass (`HDRToneMapper.pixelScale`) on the GPU, for HDR's
/// on-screen previews while sliders move (Rosh, Nov 12, 2026: "still the main image with
/// sliders are bit laggy"). The exposure analysis is still made on the CPU, once per Exposure
/// value (`HDRToneMapper.analyze`); it and the photo are uploaded once (`Source`), so a Range,
/// Texture or Artifacts change is one small kernel straight into the photo view's surface, with
/// no CPU pass, no float bitmap built and no read-back.
///
/// The kernel does the same arithmetic as `pixelScale`, in the same order, in 32-bit floats; the
/// GPU's `exp2`/`pow` can differ from the CPU's in the last bits, far below one step of the 8-bit
/// preview. The saved TIFF and the full-size view at 100% and closer still come from the CPU.
public final class HDRPreviewRenderer: @unchecked Sendable {
    /// Nil when the kernel doesn't build on this Mac; previews then use the CPU renderer.
    public static let shared: HDRPreviewRenderer? = HDRPreviewRenderer()

    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private let kernel: CIKernel
    /// The same working space and format as `HDRImageIO`'s previews. Intermediates are cached,
    /// so a `Source`'s uploaded images are reused from render to render.
    private let context = CIContext(options: [.workingColorSpace: HDRImageIO.linear,
                                              .workingFormat: CIFormat.RGBAf,
                                              .cacheIntermediates: true])

    /// A photo and its exposure analysis, uploaded for the kernel.
    public final class Source: @unchecked Sendable {
        public let width: Int
        public let height: Int
        public let exposure: Float
        let rgb: CIImage
        /// Luminance, its log2, the fine blur and the edge-aware base, in R, G, B and A, stored
        /// as they are (no color matching).
        let analysis: CIImage

        init(width: Int, height: Int, exposure: Float, rgb: CIImage, analysis: CIImage) {
            self.width = width; self.height = height; self.exposure = exposure
            self.rgb = rgb; self.analysis = analysis
        }

        public func matches(_ image: HDRImage, exposure: Float) -> Bool {
            width == image.width && height == image.height && self.exposure == exposure
        }
    }

    private init?() {
        guard let kernel = (try? CIKernel.kernels(withMetalString: Self.kernelSource))?.first else { return nil }
        self.kernel = kernel
    }

    /// Uploads `image` and its `analysis` (made from it) for previews.
    public func source(_ image: HDRImage, analysis: HDRToneMapper.Analysis) -> Source? {
        guard analysis.width == image.width, analysis.height == image.height else { return nil }
        let width = image.width, height = image.height
        var packed = [Float](repeating: 0, count: width * height * 4)
        analysis.luminance.withUnsafeBufferPointer { luminance in
            analysis.logs.withUnsafeBufferPointer { logs in
                analysis.small.withUnsafeBufferPointer { small in
                    analysis.large.withUnsafeBufferPointer { large in
                        packed.withUnsafeMutableBufferPointer { packed in
                            HDRToneMapper.rows(height) { y in
                                for i in (y * width)..<((y + 1) * width) {
                                    packed[i*4] = luminance[i]; packed[i*4+1] = logs[i]
                                    packed[i*4+2] = small[i]; packed[i*4+3] = large[i]
                                }
                            }
                        }
                    }
                }
            }
        }
        let size = CGSize(width: width, height: height)
        let data = packed.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: width * 16, size: size,
                                                     format: .RGBAf, colorSpace: nil) }
        return Source(width: width, height: height, exposure: analysis.exposure,
                      rgb: HDRImageIO.linearImage(image).insertingIntermediate(cache: true),
                      analysis: data.insertingIntermediate(cache: true))
    }

    /// The tone-mapped photo, linear sRGB, as `HDRToneMapper.render` makes it. `settings.exposure`
    /// must be the source's.
    public func image(_ source: Source, settings: HDRSettings) -> CIImage? {
        guard settings.toneEnabled else { return source.rgb }
        let arguments: [Any] = [
            source.rgb, source.analysis,
            settings.method == .direct ? 0.0 : 1.0,
            Double(powf(2, settings.exposure)),
            Double(settings.compression), Double(settings.microcontrast), Double(settings.detail),
            settings.artifactsEnabled ? 1.0 : 0.0,
            Double(settings.shadowProtection), Double(settings.highlightProtection),
            Double(settings.shadows), Double(settings.highlights),
        ]
        return kernel.apply(extent: source.rgb.extent, roiCallback: { _, rect in rect }, arguments: arguments)
    }

    /// Renders `image` into `surface` (8-bit, as the photo view shows it), tagged sRGB like the
    /// CPU previews, and waits for the GPU. False if the render failed.
    public func render(_ image: CIImage, to surface: IOSurface, flipped: Bool) -> Bool {
        let destination = CIRenderDestination(ioSurface: surface)
        destination.colorSpace = Self.sRGB
        destination.isFlipped = flipped
        do {
            let task = try context.startTask(toRender: image, from: image.extent, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
            return true
        } catch {
            return false
        }
    }

    /// An ordinary 8-bit sRGB image of `image`, like `HDRImageIO.preview`.
    public func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.sRGB)
    }

    /// `HDRToneMapper.pixelScale` and `toneCurve`, line for line.
    static let kernelSource = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        static float atelierHDRCurve(float l, float lg, float large, float method, float compression) {
            if (method < 0.5) {
                float anchor = log2(0.18);
                float blackProtection = min(1.0, max(0.0, l / 0.06));
                float amount = compression * (large < anchor ? blackProtection : 1.0);
                float base = anchor + (large - anchor) * (1.0 - amount * 0.85);
                float local = compression == 0.0 ? l : exp2(base + lg - large);
                float shaped = compression == 0.0 ? local : 0.18 * pow(max(0.0, local / 0.18), 1.25);
                return shaped * (1.0 + compression * 0.18) / (1.0 + compression * shaped);
            }
            float sum = 0.0, weights = 0.0;
            for (int i = 0; i < 3; i++) {
                float ev = float(i * 2 - 2);
                float plate = min(1.0, l * exp2(ev));
                float t = (plate - 0.5) / 0.24;
                float weight = exp(-(t * t) / 2.0) + 0.0001;
                sum += plate * weight; weights += weight;
            }
            return l * (1.0 - compression) + (sum / weights) * compression;
        }

        [[stitchable]] float4 atelierHDRTone(coreimage::sampler image, coreimage::sampler analysis,
                                             float method, float gain, float compression,
                                             float microcontrast, float detail, float artifacts,
                                             float shadowProtection, float highlightProtection,
                                             float shadows, float highlights,
                                             coreimage::destination dest) {
            float2 p = dest.coord();
            float4 color = image.sample(image.transform(p));
            float4 a = analysis.sample(analysis.transform(p));
            float l = a.x, lg = a.y, small = a.z, large = a.w;
            float mapped = atelierHDRCurve(l, lg, large, method, compression);
            if (shadows != 0.0 || highlights != 0.0) {
                float regionTone = atelierHDRCurve(exp2(large), large, large, method, compression);
                float region = min(1.0, max(0.0, pow(max(0.0, regionTone), 1.0 / 2.2)));
                float shadowWeight = region * pow(1.0 - region, 3.0) / 0.10546875;
                float highlightWeight = pow(region, 3.0) * (1.0 - region) / 0.10546875;
                float shadowGain = 0.22 * (shadows < 0.0 ? 0.7 : 1.0) * shadows;
                float shift = 0.22 * highlights * highlightWeight + shadowGain * shadowWeight;
                mapped = pow(max(0.0, pow(max(0.0, mapped), 1.0 / 2.2) + shift), 2.2);
            }
            float shadowMask = min(1.0, l / 0.08);
            float highlightMask = 1.0 / (1.0 + max(0.0, l - 0.7) * 4.0);
            float protection = artifacts > 0.5
                ? (1.0 - shadowProtection + shadowProtection * shadowMask)
                  * (1.0 - highlightProtection + highlightProtection * highlightMask)
                : 1.0;
            float fine = max(-0.5, min(0.5, lg - small));
            float coarse = max(-0.5, min(0.5, small - large));
            float boundaryProtection = 1.0 / (1.0 + abs(lg - small) * 4.0);
            float texture = exp2(protection * (detail * fine * 2.0
                + microcontrast * coarse * 3.0 * boundaryProtection));
            float scale = l > 0.000001 ? mapped / l * gain * texture : gain;
            return float4(max(color.rgb * scale, float3(0.0)), color.a);
        }
        """
}
