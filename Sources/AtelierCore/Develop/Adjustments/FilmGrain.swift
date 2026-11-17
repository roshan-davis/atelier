import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Effects > Grain, modeled on Lightroom's (Amount, Size and Roughness), plus a Type.
///
/// The grain is a fixed, seeded noise pattern laid on the photo's own pixels, so it is the
/// same on every render of a photo. It changes luminance only (monochrome grain) and is
/// added in perceptual, display-like values: strongest in the midtones, fading toward pure
/// black and pure white, as film grain does. Particles are soft and irregular (rotated
/// octaves of value noise); Roughness mixes in a coarser octave and an uneven strength
/// across the frame, so grain clumps instead of looking like even digital noise.
///
/// Type gives the grain of a kind of film, after DxO FilmPack's per-stock grain: Standard is
/// the Lightroom-like grain above; Fine, Cubic and Tabular reshape the same field (see `Look`).
/// Every type has the same strength for an Amount, so only the character changes.
///
/// Size is in full-size photo pixels. On a smaller render (the live proxy, a thumbnail) the
/// strength drops as a downsized full-size render's would, so the preview, the loupe and an
/// export match.
enum FilmGrain {
    /// How a Grain Type shapes the field. Tuned with a numpy port of the kernel on 100% crops of
    /// a real photo and a gray ramp.
    struct Look {
        /// Particle size relative to Standard at the same Size.
        var sizeScale: Double
        /// Clumping: the type's roughness for the slider's 0...1.
        var roughness: (Double) -> Double
        /// Weight of the finer, rotated octave: low is smooth and round, high is ragged.
        var detail: Double
        /// Edge hardness (tanh gain on the unit field), 0 for soft particles, and the RMS that
        /// brings the hardened field back to unit strength.
        var crispness: Double
        var crispNorm: Double
        /// The perceptual tone where grain is strongest, and how fast it fades toward black and
        /// white (higher fades faster).
        var toneCenter: Double
        var toneFalloff: Double
        /// `visible`'s constant, fitted to box-downsized renders of this type's field.
        var blurFit: Double

        static func of(_ type: DevelopSettings.GrainType) -> Look {
            switch type {
            case .standard:
                return Look(sizeScale: 1, roughness: { $0 }, detail: 0.6, crispness: 0, crispNorm: 1,
                            toneCenter: 0.5, toneFalloff: 0.6, blurFit: 0.9)
            // Slow, fine-grain stock (Ektar, Velvia, Pan F): small, tight, crisp, even.
            case .fine:
                return Look(sizeScale: 0.7, roughness: { 0.5 * $0 }, detail: 0.6, crispness: 1.5, crispNorm: 0.748,
                            toneCenter: 0.5, toneFalloff: 0.6, blurFit: 1.7)
            // Classic cubic-crystal stock (Tri-X, HP5, Gold, Superia): larger, sharp-edged,
            // clumpy grain that reaches further into the shadows.
            case .cubic:
                return Look(sizeScale: 1.2, roughness: { 0.25 + 0.75 * $0 }, detail: 0.9, crispness: 1.4,
                            crispNorm: 0.72, toneCenter: 0.42, toneFalloff: 0.45, blurFit: 1.8)
            // Tabular (T-grain) stock (Portra, T-Max, Delta, Vision3): flat crystals, so smooth,
            // soft, even grain that leaves shadows and highlights cleaner.
            case .tabular:
                return Look(sizeScale: 1, roughness: { 0.4 * $0 }, detail: 0.3, crispness: 0, crispNorm: 1,
                            toneCenter: 0.55, toneFalloff: 1.2, blurFit: 0.6)
            }
        }

        /// RMS of the kernel's raw field for roughness `r`, so every type and roughness has the
        /// same strength. Each octave of value noise has RMS 0.4527.
        func fieldRMS(roughness r: Double) -> Double {
            let octave = 0.4527 * 0.4527
            let base = octave * (1 + detail * detail) * (1 - 0.3 * r) * (1 - 0.3 * r) + octave * 0.64 * r * r
            return (base * (1 + 0.36 * r * r * octave)).squareRoot()
        }
    }

    /// Grain particle size in full-size pixels for Size 0...1: 1 px at 0, about 1.7 at the
    /// default 25, 8 at 100 (for Standard; a type scales it).
    static func particleSize(size: Double, type: DevelopSettings.GrainType = .standard) -> Double {
        pow(2, 3 * size) * Look.of(type).sizeScale
    }

    /// How much of a grain field's contrast survives averaging into pixels `e` grains wide
    /// (fitted to box-downsized renders of the kernel's field).
    private static func visible(_ e: Double, _ look: Look) -> Double { e / (e * e + look.blurFit).squareRoot() }

    /// At one grain per pixel the kernel samples cell centers, which flattens the noise.
    private static func sampled(_ e: Double) -> Double { e <= 1 ? 0.79 : 1 }

    /// Grain at Amount, Size and Roughness (each 0...1) of a Type. `scale` is the render's size
    /// relative to the full photo.
    static func apply(_ image: CIImage, amount: Double, size: Double, roughness: Double,
                      type: DevelopSettings.GrainType = .standard, scale: Double, extent: CGRect) -> CIImage {
        guard let kernel = kernel else { return image }
        var image = image
        // Lightroom softens the photo a little at larger sizes, so big grain replaces detail.
        if size > 0.25 {
            let sigma = (size - 0.25) / 0.75 * 1.2 * scale
            if sigma >= 0.3 {
                image = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            }
        }
        let look = Look.of(type)
        let rough = min(max(look.roughness(roughness), 0), 1)
        let particle = particleSize(size: size, type: type)
        let onScreen = particle * max(scale, 0.0001)
        let cell = max(onScreen, 1)
        let strength = 0.10 * amount * (visible(onScreen, look) / visible(particle, look)) / sampled(onScreen)
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                            arguments: [image, CIVector(x: strength, y: rough, z: cell, w: look.fieldRMS(roughness: rough)),
                                        CIVector(x: extent.minX, y: extent.minY),
                                        CIVector(x: look.detail, y: look.crispness, z: look.crispNorm, w: 0),
                                        CIVector(x: look.toneCenter, y: look.toneFalloff)])?.cropped(to: extent) ?? image
    }

    /// Whether the kernel built, for tests.
    static var kernelAvailable: Bool { kernel != nil }

    /// Built from Metal at run time, like the lens warp. Without it grain is left off.
    private static let kernel: CIKernel? = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            static float atelierGrainHash(int2 p, uint seed) {
                uint h = (uint(p.x) * 0x8da6b343u) ^ (uint(p.y) * 0xd8163841u) ^ (seed * 0xcb1ab31fu);
                h ^= h >> 15; h *= 0x2c1b3c6du;
                h ^= h >> 12; h *= 0x297a2d39u;
                h ^= h >> 15;
                return float(h) * (2.0 / 4294967295.0) - 1.0;
            }

            // Smooth value noise in -1...1 with cells one unit wide.
            static float atelierValueNoise(float2 p, uint seed) {
                float2 i = floor(p);
                float2 f = p - i;
                float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
                int2 c = int2(i);
                float a = atelierGrainHash(c, seed);
                float b = atelierGrainHash(c + int2(1, 0), seed);
                float d = atelierGrainHash(c + int2(0, 1), seed);
                float e = atelierGrainHash(c + int2(1, 1), seed);
                return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
            }

            static float2 atelierRotate(float2 p, float angle) {
                float c = cos(angle), s = sin(angle);
                return float2(c * p.x - s * p.y, s * p.x + c * p.y);
            }

            // grain: strength, roughness 0...1, cell size in output pixels, the field's RMS.
            // origin: the frame's corner. look: detail octave weight, crispness and its RMS.
            // tone: where grain is strongest (perceptual) and its falloff exponent.
            [[stitchable]] float4 atelierGrain(coreimage::sampler image, float4 grain, float2 origin,
                                               float4 look, float2 tone, coreimage::destination dest) {
                float4 color = image.sample(image.transform(dest.coord()));
                float2 q = (dest.coord() - origin) / grain.z;
                float r = grain.y;
                float fine = atelierValueNoise(q, 1u)
                    + look.x * atelierValueNoise(atelierRotate(q, 1.1) * 1.7 + float2(17.3, 5.1), 2u);
                float clump = atelierValueNoise(atelierRotate(q, 2.3) / 1.8 + float2(3.7, 9.2), 3u);
                float g = fine * (1.0 - 0.3 * r) + clump * 0.8 * r;
                g *= 1.0 + 0.6 * r * atelierValueNoise(atelierRotate(q, 0.7) / 3.5 + float2(1.3, 7.7), 4u);
                g /= grain.w;
                if (look.y > 0.0) {
                    g = tanh(look.y * g) / look.z;
                }

                float luma = max(dot(color.rgb, float3(0.2627, 0.6780, 0.0593)), 0.0);
                float lp = pow(luma, 1.0 / 2.2);
                float x = lp < tone.x ? 0.5 * lp / tone.x : 0.5 + 0.5 * (lp - tone.x) / (1.0 - tone.x);
                float w = pow(clamp(4.0 * x * (1.0 - x), 0.0, 1.0), tone.y);
                float grained = pow(max(lp + grain.x * w * g, 0.0), 2.2);
                float3 rgb = luma > 1e-4 ? color.rgb * (grained / luma) : color.rgb + (grained - luma);
                return float4(rgb, color.a);
            }
            """
        return (try? CIKernel.kernels(withMetalString: source))?.first { $0.name == "atelierGrain" }
    }()
}
