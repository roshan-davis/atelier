import Foundation

/// What the AI tool can do to a photo. Each recipe runs a ComfyUI workflow whose inputs are
/// found by node title ("Atelier Image", "Atelier Mask", ...), so a workflow saved in
/// `Workflows/<recipe>.json` (API format) can replace the built-in one.
public enum AIRecipe: String, CaseIterable, Codable, Sendable {
    case removeObject = "remove-object"
    case replaceBackground = "replace-background"
    case upscale

    public var title: String {
        switch self {
        case .removeObject: return "Remove Object"
        case .replaceBackground: return "Replace Background"
        case .upscale: return "Upscale"
        }
    }

    public var symbol: String {
        switch self {
        case .removeObject: return "eraser"
        case .replaceBackground: return "person.crop.rectangle"
        case .upscale: return "arrow.up.left.and.arrow.down.right"
        }
    }

    public var summary: String {
        switch self {
        case .removeObject: return "Paint over what should go. Only the painted area changes."
        case .replaceBackground: return "Atelier finds the subject and keeps it; the rest is generated from your prompt."
        case .upscale: return "Enlarges the photo with an upscaling model."
        }
    }

    /// Whether the recipe paints with the brush.
    public var usesBrush: Bool { self == .removeObject }
    public var usesPrompt: Bool { self != .upscale }

    public var defaultPrompt: String {
        switch self {
        case .removeObject: return "empty background, seamless continuation of the surroundings, natural texture"
        case .replaceBackground: return ""
        case .upscale: return ""
        }
    }

    /// Where a user's workflow for this recipe is looked for.
    public static var workflowsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Workflows", isDirectory: true)
    }

    public var workflowURL: URL { Self.workflowsFolder.appendingPathComponent("\(rawValue).json") }

    /// The user's workflow when there is one, otherwise the built-in.
    public func workflow() throws -> (graph: [String: Any], isCustom: Bool) {
        if let data = try? Data(contentsOf: workflowURL) {
            guard let graph = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIError("\(workflowURL.lastPathComponent) is not a ComfyUI workflow in API format.")
            }
            return (graph, true)
        }
        return (try JSONSerialization.jsonObject(with: Data(builtInWorkflow.utf8)) as! [String: Any], false)
    }

    /// Writes the built-in workflows into the Workflows folder, so they can be opened in
    /// ComfyUI and changed. Existing files are left alone.
    public static func installWorkflowTemplates() throws {
        try FileManager.default.createDirectory(at: workflowsFolder, withIntermediateDirectories: true)
        for recipe in allCases where !FileManager.default.fileExists(atPath: recipe.workflowURL.path) {
            try Data(recipe.builtInWorkflow.utf8).write(to: recipe.workflowURL.deletingPathExtension()
                .appendingPathExtension("example.json"))
        }
    }

    var builtInWorkflow: String {
        switch self {
        case .removeObject, .replaceBackground: return Self.inpaintWorkflow
        case .upscale: return Self.upscaleWorkflow
        }
    }

    /// Core nodes only: an inpainting checkpoint fills the masked area.
    static let inpaintWorkflow = """
        {
          "1": {"class_type": "CheckpointLoaderSimple", "_meta": {"title": "Atelier Checkpoint"},
                "inputs": {"ckpt_name": "inpainting.safetensors"}},
          "2": {"class_type": "LoadImage", "_meta": {"title": "Atelier Image"}, "inputs": {"image": "input.png"}},
          "3": {"class_type": "LoadImageMask", "_meta": {"title": "Atelier Mask"},
                "inputs": {"image": "mask.png", "channel": "red"}},
          "4": {"class_type": "CLIPTextEncode", "_meta": {"title": "Atelier Prompt"},
                "inputs": {"text": "", "clip": ["1", 1]}},
          "5": {"class_type": "CLIPTextEncode", "_meta": {"title": "Atelier Negative Prompt"},
                "inputs": {"text": "blurry, artifacts, text, watermark, frame, border", "clip": ["1", 1]}},
          "6": {"class_type": "VAEEncodeForInpaint",
                "inputs": {"pixels": ["2", 0], "vae": ["1", 2], "mask": ["3", 0], "grow_mask_by": 8}},
          "7": {"class_type": "KSampler", "_meta": {"title": "Atelier Sampler"},
                "inputs": {"seed": 0, "steps": 30, "cfg": 6.5, "sampler_name": "dpmpp_2m", "scheduler": "karras",
                           "denoise": 1.0, "model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0],
                           "latent_image": ["6", 0]}},
          "8": {"class_type": "VAEDecode", "inputs": {"samples": ["7", 0], "vae": ["1", 2]}},
          "9": {"class_type": "SaveImage", "_meta": {"title": "Atelier Output"},
                "inputs": {"images": ["8", 0], "filename_prefix": "Atelier"}}
        }
        """

    /// Core nodes only: a 4x upscaling model, then scaled to the chosen factor.
    static let upscaleWorkflow = """
        {
          "1": {"class_type": "LoadImage", "_meta": {"title": "Atelier Image"}, "inputs": {"image": "input.png"}},
          "2": {"class_type": "UpscaleModelLoader", "_meta": {"title": "Atelier Upscale Model"},
                "inputs": {"model_name": "4x-upscaler.pth"}},
          "3": {"class_type": "ImageUpscaleWithModel", "inputs": {"upscale_model": ["2", 0], "image": ["1", 0]}},
          "4": {"class_type": "ImageScaleBy", "_meta": {"title": "Atelier Output Scale"},
                "inputs": {"image": ["3", 0], "upscale_method": "lanczos", "scale_by": 0.5}},
          "5": {"class_type": "SaveImage", "_meta": {"title": "Atelier Output"},
                "inputs": {"images": ["4", 0], "filename_prefix": "Atelier"}}
        }
        """
}

/// Fills a workflow's inputs by node title.
public enum WorkflowBinder {
    /// `values` maps a node title to the inputs to set on it. Titles in `required` must exist.
    public static func bind(_ graph: [String: Any], values: [String: [String: Any]],
                            required: Set<String> = []) throws -> [String: Any] {
        var graph = graph
        var found: Set<String> = []
        for (id, value) in graph {
            guard var node = value as? [String: Any],
                  let title = (node["_meta"] as? [String: Any])?["title"] as? String,
                  let inputs = values[title] else { continue }
            var nodeInputs = node["inputs"] as? [String: Any] ?? [:]
            for (key, input) in inputs { nodeInputs[key] = input }
            node["inputs"] = nodeInputs
            graph[id] = node
            found.insert(title)
        }
        if let missing = required.subtracting(found).sorted().first {
            throw AIError("The workflow has no node titled \u{201C}\(missing)\u{201D}. Title the node in ComfyUI (right-click > Title) and save it again in API format.")
        }
        return graph
    }
}
