import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Lightroom's Option-drag views: while Option is held on certain sliders, the photo shows what
/// that slider does instead of the finished look.
public enum SliderPreview: Hashable, Sendable {
    /// Sharpening Amount: the photo in grayscale, so color doesn't hide the sharpening.
    case sharpenAmount
    /// Sharpening Radius and Detail: only the sharpening's edge halos, on mid gray.
    case sharpenEdges
    /// Sharpening Masking: white where sharpening applies, black where it is masked out.
    case sharpenMask
    /// Exposure, Highlights and Whites: black, with clipped highlights in the color of the
    /// clipped channels (white where all three clip).
    case highlightClipping
    /// Shadows and Blacks: white, with clipped shadows in the color of the channels still
    /// above black (black where all three clip).
    case shadowClipping
    /// Color Grading hue: the region's tint at full saturation, so the hue is easy to judge.
    case fullSaturation(DevelopSettings.GradeRegion)
    /// Color Grading Blending: every wheel that has a tint at full saturation, so the overlap
    /// between them is easy to see.
    case blendingSaturation
    /// Color Grading Balance: the photo in the colors of the tonal ranges (blue shadows, gray
    /// midtones, yellow highlights), so the split is easy to see.
    case gradeRegions
    /// Color Grading's eye button: the photo graded by one wheel alone.
    case gradeSolo(DevelopSettings.GradeRegion)
    /// Point Color's Visualize Range: the colors the swatch (0...3) selects, everything else gray.
    case pointColorRange(Int)
    /// Defringe Amount: white, with the fringes being turned neutral shown in their color.
    case defringeAmount(DevelopSettings.FringeColor)
    /// Defringe Hue: black outside the Hue range, so it shows which colors can be affected.
    case defringeHue(DevelopSettings.FringeColor)
    /// The Remove tool's Visualize Spots: white with the photo's edges in black, so sensor dust
    /// and specks stand out. The amount (0...100) is the panel's slider; higher shows more.
    case visualizeSpots(Double)
    /// Lens Blur's Visualize Depth: the depth map in color, warm near to cool far, with the
    /// focal range kept sharp lighter.
    case visualizeDepth

    /// The view Option shows while dragging `parameter`, if it has one.
    public init?(parameter: DevelopSettings.Parameter) {
        switch parameter {
        case .sharpening: self = .sharpenAmount
        case .sharpenRadius, .sharpenDetail: self = .sharpenEdges
        case .sharpenMasking: self = .sharpenMask
        case .exposure, .highlights, .whites: self = .highlightClipping
        case .shadows, .blacks: self = .shadowClipping
        case .lensDefringePurpleAmount: self = .defringeAmount(.purple)
        case .lensDefringeGreenAmount: self = .defringeAmount(.green)
        case .lensDefringePurpleHueLow, .lensDefringePurpleHueHigh: self = .defringeHue(.purple)
        case .lensDefringeGreenHueLow, .lensDefringeGreenHueHigh: self = .defringeHue(.green)
        case .gradeBlending: self = .blendingSaturation
        case .gradeBalance: self = .gradeRegions
        default:
            guard let region = DevelopSettings.GradeRegion.allCases.first(where: { $0.hue == parameter }) else { return nil }
            self = .fullSaturation(region)
        }
    }

    /// Tooltip text for a slider with this view.
    public var hint: String {
        switch self {
        case .sharpenAmount: return "Hold Option while dragging to see sharpening in grayscale"
        case .sharpenEdges: return "Hold Option while dragging to see the sharpened edges"
        case .sharpenMask: return "Hold Option while dragging to see where sharpening applies (white)"
        case .highlightClipping: return "Hold Option while dragging to see clipped highlights"
        case .shadowClipping: return "Hold Option while dragging to see clipped shadows"
        case .fullSaturation: return "Hold Option while dragging to see the hue at full saturation"
        case .blendingSaturation: return "Hold Option while dragging to see the tints at full saturation"
        case .gradeRegions: return "Hold Option while dragging to see the shadows (blue), midtones (gray) and highlights (yellow)"
        case .gradeSolo(let region): return "Press and hold to see the photo with only the \(region.rawValue) wheel"
        case .pointColorRange: return "Shows the colors this swatch changes; the rest turns gray"
        case .defringeAmount: return "Hold Option while dragging to see the fringes being removed (in color, on white)"
        case .defringeHue: return "Hold Option while dragging to see which colors the range covers (the rest turns black)"
        case .visualizeSpots: return "Shows the photo's edges in black on white, so dust and specks stand out"
        case .visualizeDepth: return "Shows the depth: warm is near, cool is far, and the focal range kept sharp is lighter"
        }
    }

    /// The Defringe view this is, if it is one.
    var defringeView: Defringe.View? {
        switch self {
        case .defringeAmount(let color): return .amount(color)
        case .defringeHue(let color): return .hue(color)
        default: return nil
        }
    }

    // MARK: Rendering

    /// Built from Metal at run time, like the lens warp. Without them the views fall back to
    /// the photo itself.
    private static let kernels: [String: CIKernel] = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            static float atelierLuma(coreimage::sampler image, float2 p) {
                float3 c = max(image.sample(image.transform(p)).rgb, float3(0.0));
                return pow(dot(c, float3(0.2627, 0.6780, 0.0593)), 1.0 / 2.2);
            }

            // Mid gray plus the sharpening's change in perceptual luminance.
            [[stitchable]] float4 atelierHalos(coreimage::sampler base, coreimage::sampler sharp, float gain,
                                               coreimage::destination dest) {
                float d = atelierLuma(sharp, dest.coord()) - atelierLuma(base, dest.coord());
                float g = pow(clamp(0.5 + gain * d, 0.0, 1.0), 2.2);
                return float4(g, g, g, 1.0);
            }

            // White on edges whose contrast passes the threshold, fading to black on flat areas.
            [[stitchable]] float4 atelierEdgeMask(coreimage::sampler image, float threshold, float softness,
                                                  float scale, coreimage::destination dest) {
                float2 p = dest.coord();
                float gx = atelierLuma(image, p + float2(1.0, 0.0)) - atelierLuma(image, p - float2(1.0, 0.0));
                float gy = atelierLuma(image, p + float2(0.0, 1.0)) - atelierLuma(image, p - float2(0.0, 1.0));
                float m = length(float2(gx, gy)) * 0.5 * scale;
                float v = smoothstep(threshold, threshold + softness, m);
                return float4(v, v, v, 1.0);
            }

            // Values here are display-encoded: 1 is the brightest the screen shows, 0 black.
            [[stitchable]] float4 atelierClipping(coreimage::sampler image, float highlights,
                                                  coreimage::destination dest) {
                float3 c = image.sample(image.transform(dest.coord())).rgb;
                if (highlights > 0.5) { return float4(step(float3(0.998), c), 1.0); }
                return float4(step(float3(0.002), c), 1.0);
            }
            """
        guard let built = try? CIKernel.kernels(withMetalString: source) else { return [:] }
        return Dictionary(built.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// Whether the views' kernels built, for tests.
    static var kernelsAvailable: Bool { kernels.count == 3 }

    /// The sharpening halos alone on mid gray: what Radius and Detail change.
    static func halos(base: CIImage, sharpened: CIImage) -> CIImage {
        let extent = base.extent
        guard let kernel = kernels["atelierHalos"] else { return sharpened }
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [base, sharpened, 6.0])
            ?? sharpened
    }

    /// Where sharpening applies for a Masking value (0...100): everywhere at 0, only the
    /// strongest edges at 100. `scale` is the render's size relative to the full photo, so the
    /// mask matches between the live proxy and an export.
    static func edgeMask(_ image: CIImage, masking: Double, scale: Double) -> CIImage {
        let extent = image.extent
        let white = CIImage(color: .white).cropped(to: extent)
        guard masking > 0, let kernel = kernels["atelierEdgeMask"] else { return white }
        // A little blur first, so noise and fine texture fall out of the mask before edges do.
        let smoothed = image.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, 1.5 * scale))
        let threshold = pow(masking / 100, 1.5) * 0.12
        let softness = max(0.004, threshold * 0.6)
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
                            arguments: [smoothed, threshold, softness, scale])?.cropped(to: extent) ?? white
    }

    /// The clipping view for highlights or shadows, measured on the display's colors.
    static func clipping(_ image: CIImage, highlights: Bool) -> CIImage {
        let extent = image.extent
        guard let kernel = kernels["atelierClipping"],
              let display = image.matchedFromWorkingSpace(to: DevelopRenderer.displaySpace),
              let marked = kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                                        arguments: [display, highlights ? 1.0 : 0.0]) else { return image }
        return marked.matchedToWorkingSpace(from: DevelopRenderer.displaySpace) ?? marked
    }

    static func grayscale(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = 0
        filter.brightness = 0
        filter.contrast = 1
        return filter.outputImage ?? image
    }
}
