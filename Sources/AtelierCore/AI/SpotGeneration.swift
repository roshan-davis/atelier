import CoreGraphics
import CoreImage
import Foundation

/// Generative AI for the Remove tool (AT-066 step 4): a Content-Aware spot's fill made by the
/// Remove Object recipe in ComfyUI instead of found in the photo, for objects too large or
/// too unlike their surroundings to fill from texture.
///
/// The model sees the photo as it is under the spot (corrected, with the spots before it, no
/// tone or color steps), the area around the spot for context, and the spot's brush as the
/// hole. The result is kept as the spot's patch (`SpotPatches`) and drawn with the spot's own
/// feather and opacity, so it stays an edit: the original is never written.
public enum SpotGeneration {
    /// What is sent for one spot.
    public struct Input: @unchecked Sendable {
        /// The area around the spot, sRGB, at full size.
        public let image: CGImage
        /// White where the model fills, the same size as `image`.
        public let mask: CGImage
        /// Where `image` sits, in fractions of the upright, uncropped photo (top-left origin).
        public let region: DevelopSettings.MaskRect
        /// The area's average color in the working space (see `Spot.Patch.mean`).
        public let mean: [Double]
    }

    /// The input for `spot` on `image` (the corrected photo with the spots before it, uncropped,
    /// at full size), or nil when the area can't be read.
    static func prepare(_ spot: DevelopSettings.Spot, on image: CIImage, context: CIContext) -> Input? {
        let extent = image.extent
        let photo = extent.size
        guard photo.width >= 8, photo.height >= 8, !spot.points.isEmpty else { return nil }
        let box = spot.bounds(in: photo).intersection(CGRect(origin: .zero, size: photo))
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        let area = AIImaging.contextRegion(around: box, imageSize: photo)
        guard area.width >= 8, area.height >= 8 else { return nil }
        // Core Image's y axis points up.
        let region = CGRect(x: extent.minX + area.minX, y: extent.minY + photo.height - area.maxY,
                            width: area.width, height: area.height)
        let local = image.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        guard let cgImage = context.createCGImage(local, from: CGRect(origin: .zero, size: area.size),
                                                  format: .RGBA8, colorSpace: AIImaging.sRGB),
              let mean = SpotPatches.mean(of: image, in: region, context: context) else { return nil }
        // The brush, a little larger, so the object's edge is generated too.
        let radius = CGFloat(spot.size) * max(photo.width, photo.height) / 2 * 1.1 + 2
        let points = spot.points.map {
            CGPoint(x: (CGFloat($0.x) * photo.width - area.minX) / area.width,
                    y: (CGFloat($0.y) * photo.height - area.minY) / area.height)
        }
        guard let mask = AIImaging.mask(from: [BrushStroke(points: points, radius: Double(radius / area.width))],
                                        width: Int(area.width), height: Int(area.height)) else { return nil }
        let fractions = DevelopSettings.MaskRect(x: Double(area.minX / photo.width), y: Double(area.minY / photo.height),
                                                 width: Double(area.width / photo.width),
                                                 height: Double(area.height / photo.height))
        return Input(image: cgImage, mask: mask, region: fractions, mean: mean)
    }
}

extension DevelopSession {
    /// What Generative AI sends for spot `id` of `settings`; nil when it isn't one of them or the
    /// photo can't be read. Use a full-size session (no `maxPixelSize`); this renders, so call it
    /// off the main thread.
    public func spotGenerationInput(for id: UUID, settings: DevelopSettings) -> SpotGeneration.Input? {
        guard let spot = settings.spots.first(where: { $0.id == id }),
              let image = imageUnderSpot(id, settings: settings) else { return nil }
        return SpotGeneration.prepare(spot, on: image, context: renderContext)
    }
}

extension AIRunner {
    /// Generates the fill for one Remove tool spot with the Remove Object recipe and keeps it in
    /// `patches`. Returns the patch for the spot.
    public func generateFill(_ input: SpotGeneration.Input, seed: UInt32, settings: AISettings,
                             patches: SpotPatches = .shared,
                             progress report: @escaping @Sendable (AIProgress) -> Void = { _ in })
        async throws -> DevelopSettings.Spot.Patch {
        let recipe = AIRecipe.removeObject
        let (graph, isCustom) = try recipe.workflow()
        report(AIProgress("Sending to ComfyUI"))
        let size = CGSize(width: input.image.width, height: input.image.height)
        let work = AIImaging.workSize(for: size, longEdge: settings.generationSize)
        guard let image = AIImaging.resize(input.image, to: work).flatMap(AIImaging.pngData),
              let mask = AIImaging.resize(input.mask, to: work).flatMap(AIImaging.rgbPNG(fromMask:))
        else { throw AIError("The photo could not be prepared.") }
        let token = UUID().uuidString.prefix(8)
        let imageName = try await client.upload(png: image, name: "atelier-spot-\(token).png")
        let maskName = try await client.upload(png: mask, name: "atelier-spot-\(token)-mask.png")
        let instruction = recipe.instruction(for: "")
        var values: [String: [String: Any]] = [
            "Atelier Image": ["image": imageName],
            "Atelier Mask": ["image": maskName],
            "Atelier Prompt": ["text": instruction, "prompt": instruction],
            "Atelier Sampler": ["seed": Int(seed)],
        ]
        if let editModel = settings.editModel { values["Atelier Edit Model"] = ["unet_name": editModel] }
        let workflow = try WorkflowBinder.bind(graph, values: values, required: ["Atelier Image", "Atelier Mask"])
        let generated = try await generate(workflow, timingsKey: "\(recipe.rawValue)-\(settings.generationSize)",
                                           report: report)
        report(AIProgress("Saving"))
        let patch = DevelopSettings.Spot.Patch(region: input.region, mean: input.mean, seed: seed)
        let provenance: [String: Any] = [
            "recipe": recipe.rawValue,
            "use": "remove-spot",
            "workflow": isCustom ? recipe.workflowURL.lastPathComponent : "built-in",
            "editModel": settings.editModel ?? "workflow default",
            "models": models(for: recipe, isCustom: isCustom, settings: settings),
            "seed": Int(seed),
            "generationSize": [Int(work.width), Int(work.height)],
            "server": settings.server.absoluteString,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        try patches.save(generated, id: patch.id, provenance: provenance)
        return patch
    }
}
