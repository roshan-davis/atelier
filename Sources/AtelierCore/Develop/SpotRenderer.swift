import CoreGraphics
import CoreImage
import Foundation

/// Draws the Remove tool's spots (AT-066) onto the corrected photo, in order, each one only
/// over its own small area.
///
/// - Clone: the source, moved onto the spot, with the brush's soft edge.
/// - Heal: the source's texture with the spot's own colors. The difference between the photo
///   and the source on a thin ring just outside the spot is spread smoothly over the inside (a
///   normalized blur at two sizes, a fast stand-in for the smooth "membrane" of Poisson
///   healing) and added to the source, so the fill meets its surroundings with no visible seam.
///
/// Spots work in the corrected photo's pixels, before every tone and color step, so a tone
/// slider never redraws them; the brush shapes are kept in a `SpotShapeCache` per open photo.
enum SpotRenderer {
    /// `image` with `spots` drawn on it. `image` is the corrected photo, upright and uncropped.
    static func apply(_ spots: [DevelopSettings.Spot], to image: CIImage, cache: SpotShapeCache? = nil) -> CIImage {
        guard !spots.isEmpty, let kernels, !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        var result = image
        for spot in spots where !spot.points.isEmpty && spot.opacity > 0 {
            result = apply(spot, to: result, kernels: kernels, cache: cache)
        }
        return result
    }

    private static func apply(_ spot: DevelopSettings.Spot, to image: CIImage, kernels: [String: CIKernel],
                              cache: SpotShapeCache?) -> CIImage {
        let extent = image.extent
        let photo = extent.size
        let radius = max(1, CGFloat(spot.size) * max(photo.width, photo.height) / 2)
        let band = max(2, radius * 0.2)
        // The area the spot changes, top-left origin, with room for the ring.
        let area = spot.bounds(in: photo, margin: band + 2).integral
            .intersection(CGRect(origin: .zero, size: photo))
        guard !area.isNull, area.width >= 1, area.height >= 1,
              let shapes = shapes(for: spot, area: area, photo: photo, radius: radius, band: band, cache: cache)
        else { return image }
        // Core Image's y axis points up.
        let region = CGRect(x: extent.minX + area.minX, y: extent.minY + photo.height - area.maxY,
                            width: area.width, height: area.height)
        let place = CGAffineTransform(translationX: region.minX, y: region.minY)
        let mask = shapes.fill.transformed(by: place)
        // The source is read from the photo itself, `shift` away (Core Image's y points up) and
        // kept inside `bounds`, in the kernels.
        //
        // The fill is drawn by one pass over the whole photo that leaves every pixel outside
        // `area` as it is, never a small piece cropped and composited over the photo. With the
        // small piece, the photo came out as that piece with its edges stretched over the whole
        // frame (Rosh, Nov 14, 2026).
        let shift = CIVector(x: CGFloat(spot.offset.x) * photo.width, y: -CGFloat(spot.offset.y) * photo.height)
        let bounds = CIVector(x: extent.minX + 0.5, y: extent.minY + 0.5, z: extent.maxX - 0.5, w: extent.maxY - 0.5)
        let inside = CIVector(x: region.minX, y: region.minY, z: region.maxX, w: region.maxY)
        let opacity = spot.opacity / 100
        // The photo (input 0) is read at each pixel and `shift` away; the other inputs only at it.
        let dx = CGFloat(spot.offset.x) * photo.width, dy = -CGFloat(spot.offset.y) * photo.height
        let roi: CIKernelROICallback = { index, rect in
            index == 0 ? rect.union(rect.offsetBy(dx: dx, dy: dy)).insetBy(dx: -1, dy: -1) : rect
        }
        let filled: CIImage?
        switch spot.mode {
        case .clone:
            filled = kernels["atelierSpotBlend"]?.apply(extent: extent, roiCallback: roi,
                                                        arguments: [image, mask, shift, bounds, inside, opacity])
        case .heal:
            let outer = shapes.outer.transformed(by: place), inner = shapes.inner.transformed(by: place)
            guard let ring = kernels["atelierSpotRing"]?.apply(extent: region, roiCallback: roi,
                                                               arguments: [image, outer, inner, shift, bounds])
            else { return image }
            // Zero outside the area, so the blurs only spread what the ring measured.
            let near = ring.applyingGaussianBlur(sigma: Double(max(1, radius * 0.35))).cropped(to: region)
            let far = ring.applyingGaussianBlur(sigma: Double(max(2, radius))).cropped(to: region)
            filled = kernels["atelierSpotHeal"]?.apply(extent: extent, roiCallback: roi,
                                                       arguments: [image, near, far, mask, shift, bounds, inside, opacity])
        }
        return filled ?? image
    }

    /// The spot's brush shapes over `area`, as stored values (white is the spot): `fill` with the
    /// spot's feather, `inner` the hard brush, `outer` the hard brush grown by `band` (Heal's
    /// ring is `outer` minus `inner`).
    struct Shapes {
        let fill: CIImage
        let inner: CIImage
        let outer: CIImage
    }

    private static func shapes(for spot: DevelopSettings.Spot, area: CGRect, photo: CGSize, radius: CGFloat,
                               band: CGFloat, cache: SpotShapeCache?) -> Shapes? {
        let key = SpotShapeCache.Key(points: spot.points, size: spot.size, feather: spot.feather,
                                     width: Int(photo.width.rounded()), height: Int(photo.height.rounded()))
        if let cached = cache?.shapes(for: key) { return cached }
        let points = spot.points.map {
            CGPoint(x: CGFloat($0.x) * photo.width - area.minX, y: CGFloat($0.y) * photo.height - area.minY)
        }
        let hard = radius * CGFloat(max(0, 1 - spot.feather / 100))
        guard let fill = draw(points, radius: radius, hard: hard, size: area.size),
              let inner = draw(points, radius: radius, hard: radius, size: area.size),
              let outer = draw(points, radius: radius + band, hard: radius + band, size: area.size) else { return nil }
        let shapes = Shapes(fill: DevelopRenderer.rawMask(fill), inner: DevelopRenderer.rawMask(inner),
                            outer: DevelopRenderer.rawMask(outer))
        cache?.store(shapes, for: key)
        return shapes
    }

    /// Round dabs along `points` (top-left origin, in `size`), white on black, solid to `hard`
    /// and fading out to `radius`.
    static func draw(_ points: [CGPoint], radius: CGFloat, hard: CGFloat, size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let gray = CGColorSpaceCreateDeviceGray()
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip so points read top-down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let dabs = DevelopRenderer.dabPositions(along: points, spacing: max(1, radius / 6))
        if hard >= radius - 0.5 {
            context.setFillColor(gray: 1, alpha: 1)
            for dab in dabs {
                context.fillEllipse(in: CGRect(x: dab.x - radius, y: dab.y - radius, width: radius * 2, height: radius * 2))
            }
        } else {
            guard let gradient = CGGradient(colorSpace: gray, colorComponents: [1, 1, 1, 1, 1, 0],
                                            locations: [0, max(0, hard) / radius, 1], count: 3) else { return nil }
            for dab in dabs {
                context.drawRadialGradient(gradient, startCenter: dab, startRadius: 0, endCenter: dab, endRadius: radius,
                                           options: [])
            }
        }
        return context.makeImage()
    }

    static let kernels: [String: CIKernel]? = {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;

            // Brightness, gamma-encoded as on screen, for Visualize Spots. Helpers go before
            // the first kernel: each kernel is built from its own copy of this header.
            static float atelierSpotLuma(coreimage::sampler image, float2 p) {
                float3 c = max(image.sample(image.transform(p)).rgb, float3(0.0));
                return pow(dot(c, float3(0.2627, 0.6780, 0.0593)), 1.0 / 2.2);
            }

            // Whether `p` is in the spot's area (minX, minY, maxX, maxY).
            static bool atelierSpotInside(float2 p, float4 inside) {
                return p.x >= inside.x && p.y >= inside.y && p.x < inside.z && p.y < inside.w;
            }

            // The source for `p`: the photo `shift` away, held inside the photo's `bounds`.
            static float4 atelierSpotSource(coreimage::sampler image, float2 p, float2 shift, float4 bounds) {
                float2 q = clamp(p + shift, bounds.xy, bounds.zw);
                return image.sample(image.transform(q));
            }

            // Clone: the source over the photo, through the spot's soft edge.
            [[stitchable]] float4 atelierSpotBlend(coreimage::sampler image, coreimage::sampler mask,
                                                   float2 shift, float4 bounds, float4 inside, float opacity,
                                                   coreimage::destination dest) {
                float2 p = dest.coord();
                float4 a = image.sample(image.transform(p));
                if (!atelierSpotInside(p, inside)) { return a; }
                float4 s = atelierSpotSource(image, p, shift, bounds);
                float m = clamp(mask.sample(mask.transform(p)).r, 0.0, 1.0) * opacity;
                return float4(mix(a.rgb, s.rgb, m), a.a);
            }

            // Heal's ring: the photo minus the source, weighted by the ring (in alpha).
            [[stitchable]] float4 atelierSpotRing(coreimage::sampler image, coreimage::sampler outer,
                                                  coreimage::sampler inner, float2 shift, float4 bounds,
                                                  coreimage::destination dest) {
                float2 p = dest.coord();
                float w = clamp(outer.sample(outer.transform(p)).r - inner.sample(inner.transform(p)).r, 0.0, 1.0);
                float3 d = image.sample(image.transform(p)).rgb - atelierSpotSource(image, p, shift, bounds).rgb;
                return float4(d * w, w);
            }

            // Heal: the source plus the ring's difference spread over the inside. The near blur
            // keeps the seam exact; the far one reaches the middle of large spots.
            [[stitchable]] float4 atelierSpotHeal(coreimage::sampler image, coreimage::sampler near,
                                                  coreimage::sampler far, coreimage::sampler mask,
                                                  float2 shift, float4 bounds, float4 inside, float opacity,
                                                  coreimage::destination dest) {
                float2 p = dest.coord();
                float4 a = image.sample(image.transform(p));
                if (!atelierSpotInside(p, inside)) { return a; }
                float4 n = near.sample(near.transform(p));
                float4 f = far.sample(far.transform(p));
                float weight = n.a + 0.15 * f.a;
                float3 membrane = weight > 0.00001 ? (n.rgb + 0.15 * f.rgb) / weight : float3(0.0);
                float3 s = atelierSpotSource(image, p, shift, bounds).rgb + membrane;
                float m = clamp(mask.sample(mask.transform(p)).r, 0.0, 1.0) * opacity;
                return float4(mix(a.rgb, s, m), a.a);
            }

            // Visualize Spots: white, with edges in black, so dust and specks stand out.
            [[stitchable]] float4 atelierSpotVisualize(coreimage::sampler image, float threshold,
                                                       coreimage::destination dest) {
                float2 p = dest.coord();
                float c = atelierSpotLuma(image, p);
                float around = atelierSpotLuma(image, p + float2(1.0, 0.0)) + atelierSpotLuma(image, p - float2(1.0, 0.0))
                    + atelierSpotLuma(image, p + float2(0.0, 1.0)) + atelierSpotLuma(image, p - float2(0.0, 1.0));
                float edge = abs(around - 4.0 * c);
                float v = 1.0 - smoothstep(threshold, threshold * 1.6 + 0.01, edge);
                return float4(v, v, v, 1.0);
            }
            """
        return RuntimeKernels.build(source)
    }()

    static var kernelsAvailable: Bool { kernels?.count == 4 }

    /// Visualize Spots on the finished photo: white with its edges in black. `amount` is the
    /// panel's slider (0...100): higher shows fainter edges, so more specks.
    static func visualize(_ image: CIImage, amount: Double) -> CIImage {
        guard let kernel = kernels?["atelierSpotVisualize"] else { return image }
        let threshold = 0.01 + 0.25 * pow(1 - min(max(amount, 0), 100) / 100, 1.5)
        let extent = image.extent
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
                            arguments: [image.clampedToExtent(), threshold]) ?? image
    }
}

/// The spots' drawn brush shapes, kept per open photo so a slider change doesn't redraw them.
final class SpotShapeCache: @unchecked Sendable {
    struct Key: Hashable {
        let points: [DevelopSettings.MaskPoint]
        let size: Double
        let feather: Double
        let width: Int
        let height: Int
    }

    private var shapes: [Key: SpotRenderer.Shapes] = [:]
    private let lock = NSLock()

    func shapes(for key: Key) -> SpotRenderer.Shapes? {
        lock.lock()
        defer { lock.unlock() }
        return shapes[key]
    }

    func store(_ value: SpotRenderer.Shapes, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        // Dust can mean dozens of spots; a few of each size are kept.
        if shapes.count >= 200 { shapes.removeAll() }
        shapes[key] = value
    }
}
