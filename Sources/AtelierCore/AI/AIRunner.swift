import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How Atelier talks to ComfyUI, from Settings > AI.
public struct AISettings: Codable, Hashable, Sendable {
    public var server: URL
    /// Edit model (a diffusion model file, e.g. a Qwen-Image-Edit GGUF) for Remove Object and
    /// Replace Background; nil keeps the workflow's.
    public var editModel: String?
    /// Upscaling model (a 4x model) for Upscale; nil keeps the workflow's.
    public var upscaleModel: String?
    /// Long edge, in pixels, of what the model generates.
    public var generationSize: Int
    public var upscaleFactor: Int

    public static let defaultServer = URL(string: "http://127.0.0.1:8188")!

    public init(server: URL = AISettings.defaultServer, editModel: String? = nil, upscaleModel: String? = nil,
                generationSize: Int = 1024, upscaleFactor: Int = 2) {
        self.server = server
        self.editModel = editModel
        self.upscaleModel = upscaleModel
        self.generationSize = generationSize
        self.upscaleFactor = upscaleFactor
    }
}

public struct AIRequest: Sendable {
    public var recipe: AIRecipe
    public var prompt: String
    /// The brush mask for Remove Object, on the photo as developed and cropped.
    public var strokes: [BrushStroke]
    public var seed: UInt32

    public init(recipe: AIRecipe, prompt: String = "", strokes: [BrushStroke] = [],
                seed: UInt32 = UInt32.random(in: 0...UInt32.max)) {
        self.recipe = recipe
        self.prompt = prompt
        self.strokes = strokes
        self.seed = seed
    }
}

/// What a run is doing, for the AI tool's progress line (the Processor host's progress).
public typealias AIProgress = ProcessorProgress
/// The result, stacked on the original (the Processor host's result).
public typealias AIResult = ProcessorResult

/// Runs an AI recipe on a photo: renders it as developed, sends ComfyUI what the recipe needs,
/// blends the result back so only the masked area changes, and catalogs the outcome as a new
/// photo stacked on the original, with how it was made recorded.
public final class AIRunner: Sendable {
    let catalog: Catalog
    let client: ComfyClient
    let host: ProcessorHost

    public init(catalog: Catalog, client: ComfyClient, originals: OriginalCache? = nil) {
        self.catalog = catalog
        self.client = client
        host = ProcessorHost(catalog: catalog, originals: originals)
    }

    public func run(_ request: AIRequest, on assetID: Int64, settings: AISettings,
                    progress report: @escaping @Sendable (AIProgress) -> Void = { _ in }) async throws -> AIResult {
        let progress = { @Sendable (phase: String) in report(AIProgress(phase)) }
        let original = try host.original(of: assetID)
        let recipe = request.recipe
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if recipe == .replaceBackground, prompt.isEmpty { throw AIError("Describe the new background first.") }
        if recipe.usesBrush, request.strokes.allSatisfy(\.erases) { throw AIError("Paint over what should be removed first.") }
        let (graph, isCustom) = try recipe.workflow()

        // The photo as developed, at full size, in sRGB as the models expect.
        progress("Rendering the photo")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Atelier-AI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var render = ExportSettings(destination: temp)
        render.format = .tiff
        render.colorSpace = .sRGB
        render.metadata = .all
        let baseURL = try host.renderInput(of: assetID, settings: render)
        guard let base = AIImaging.image(at: baseURL) else { throw AIError("The photo could not be rendered.") }
        let baseSize = CGSize(width: base.width, height: base.height)

        // What to send: the image (or the part around the mask) at the generation size.
        var region = CGRect(origin: .zero, size: baseSize)
        var mask: CGImage?
        switch recipe {
        case .removeObject:
            guard let painted = AIImaging.mask(from: request.strokes, width: base.width, height: base.height),
                  let box = AIImaging.bounds(of: painted) else { throw AIError("Paint over what should be removed first.") }
            mask = painted
            region = AIImaging.contextRegion(around: box, imageSize: baseSize)
        case .replaceBackground:
            progress("Finding the subject")
            guard let subject = try AIImaging.subjectMask(for: base), let background = AIImaging.inverted(subject) else {
                throw AIError("Atelier couldn't find a subject in this photo.")
            }
            mask = background
        case .upscale:
            break
        }

        progress("Sending to ComfyUI")
        let token = UUID().uuidString.prefix(8)
        var values: [String: [String: Any]] = [:]
        var required: Set<String> = ["Atelier Image"]
        let work: CGSize
        if let mask {
            work = AIImaging.workSize(for: region.size, longEdge: settings.generationSize)
            guard let input = AIImaging.crop(base, to: region, scaledTo: work).flatMap(AIImaging.pngData),
                  let maskPNG = AIImaging.crop(mask, to: region, scaledTo: work).flatMap(AIImaging.rgbPNG(fromMask:))
            else { throw AIError("The photo could not be prepared.") }
            let imageName = try await client.upload(png: input, name: "atelier-\(token).png")
            let maskName = try await client.upload(png: maskPNG, name: "atelier-\(token)-mask.png")
            values["Atelier Image"] = ["image": imageName]
            values["Atelier Mask"] = ["image": maskName]
            let instruction = recipe.instruction(for: prompt)
            values["Atelier Prompt"] = ["text": instruction, "prompt": instruction]
            values["Atelier Sampler"] = ["seed": Int(request.seed)]
            if let editModel = settings.editModel { values["Atelier Edit Model"] = ["unet_name": editModel] }
            required.insert("Atelier Mask")
        } else {
            work = baseSize
            guard let input = AIImaging.pngData(base) else { throw AIError("The photo could not be prepared.") }
            let imageName = try await client.upload(png: input, name: "atelier-\(token).png")
            values["Atelier Image"] = ["image": imageName]
            values["Atelier Output Scale"] = ["scale_by": Double(settings.upscaleFactor) / 4]
            if let model = settings.upscaleModel { values["Atelier Upscale Model"] = ["model_name": model] }
        }
        let workflow = try WorkflowBinder.bind(graph, values: values, required: required)
        // Node times differ by recipe and by how much is generated.
        let timingsKey = mask != nil ? "\(recipe.rawValue)-\(settings.generationSize)" : recipe.rawValue
        let generated = try await generate(workflow, timingsKey: timingsKey, report: report)
        progress("Blending the result")

        let final: CGImage
        if let mask {
            // Feather a few generated pixels' worth, so the seam disappears.
            let scale = region.width / work.width
            let feather = recipe == .removeObject ? max(2, 3 * scale) : max(1, scale)
            guard let blended = AIImaging.composite(generated, into: base, region: region, mask: mask, feather: feather,
                                                    grow: recipe == .removeObject ? feather : 0) else {
                throw AIError("The result could not be blended into the photo.")
            }
            final = blended
        } else {
            final = generated
        }

        progress("Saving")
        let stem = original.deletingPathExtension().lastPathComponent
        let target = Exporter.uniqueURL(in: DerivedFiles.folder(for: original), base: "\(stem)-AI \(recipe.title)", extension: "tif")
        try write(final, to: target, metadataFrom: baseURL)

        let provenance: [String: Any] = [
            "recipe": recipe.rawValue,
            "workflow": isCustom ? recipe.workflowURL.lastPathComponent : "built-in",
            "editModel": settings.editModel ?? "workflow default",
            "models": models(for: recipe, isCustom: isCustom, settings: settings),
            "upscaleModel": recipe == .upscale ? (settings.upscaleModel ?? "workflow default") : "",
            "prompt": prompt,
            "seed": Int(request.seed),
            "generationSize": [Int(work.width), Int(work.height)],
            "region": [Int(region.minX), Int(region.minY), Int(region.width), Int(region.height)],
            "server": settings.server.absoluteString,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        return try host.registerResult(target, on: assetID, kind: .ai, name: recipe.title, provenance: json)
    }

    /// Queues `workflow` in ComfyUI, reports how far it has got, and returns the last image it
    /// made. Cancelling the task stops ComfyUI too.
    func generate(_ workflow: [String: Any], timingsKey: String,
                  report: @escaping @Sendable (AIProgress) -> Void) async throws -> CGImage {
        let monitor = await client.monitor()
        defer { monitor.close() }
        let promptID = try await client.queue(workflow)
        monitor.track(promptID, workflow: workflow, known: ComfyTimings.load(timingsKey))
        let client = self.client
        let outputs = try await withTaskCancellationHandler {
            try await client.outputs(of: promptID) { elapsed in
                report(AIProgress("Generating… \(Int(elapsed)) s", fraction: monitor.fraction()))
            }
        } onCancel: {
            Task { await client.interrupt() }
        }
        ComfyTimings.save(monitor.measured, key: timingsKey)
        guard let first = outputs.last else { throw AIError("ComfyUI returned no image.") }
        guard let generated = AIImaging.image(from: try await client.download(first)) else {
            throw AIError("ComfyUI's result could not be read.")
        }
        return generated
    }

    /// Which models made the result, with their licenses, for the license gate. Models Atelier
    /// can't vouch for (a custom workflow, a different edit model) are recorded as unknown.
    func models(for recipe: AIRecipe, isCustom: Bool, settings: AISettings) -> [[String: String]] {
        if isCustom { return [["name": recipe.workflowURL.lastPathComponent, "license": "unknown", "allowedUse": "unknown"]] }
        var models = recipe.builtInModels
        if let editModel = settings.editModel, let i = models.indices.first, models[i].file != editModel {
            models[i] = AIModel(name: editModel, file: editModel, license: "unknown", allowedUse: .unknown)
        }
        if recipe == .upscale {
            models = [AIModel(name: settings.upscaleModel ?? "workflow default", file: settings.upscaleModel ?? "",
                              license: "unknown", allowedUse: .unknown)]
        }
        return models.map { ["name": $0.name, "file": $0.file, "license": $0.license, "allowedUse": $0.allowedUse.rawValue] }
    }

    /// 16-bit TIFF, keeping the rendered photo's metadata.
    private func write(_ image: CGImage, to url: URL, metadataFrom source: URL) throws {
        var properties: [CFString: Any] = [:]
        if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) {
            properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        var image = image
        if image.bitsPerComponent < 16,
           let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: 0,
                                   space: image.colorSpace ?? AIImaging.sRGB,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let wide = context.makeImage() { image = wide }
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw AIError("Can't write to \(url.deletingLastPathComponent().path).")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AIError("Saving the result failed.") }
    }
}
