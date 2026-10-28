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
        case .removeObject: return ""
        case .replaceBackground: return ""
        case .upscale: return ""
        }
    }

    /// The instruction the edit model gets. Replace Background wraps the user's description.
    public func instruction(for prompt: String) -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .removeObject:
            // The model sees the photo with the painted area filled red, so it has nothing to copy back.
            let fill = "fill it with the surrounding background so the scene looks natural and seamless. Keep everything else unchanged."
            return prompt.isEmpty ? "Remove the red area and \(fill)"
                : "Remove the red area, which covered \(prompt), and \(fill)"
        case .replaceBackground: return "Replace the background with \(prompt). Keep the subject exactly as it is."
        case .upscale: return ""
        }
    }

    /// The models the built-in workflow loads, with their licenses, so a result can be checked
    /// against the license gate. Upscale's model is the user's pick, so its license is unknown.
    public var builtInModels: [AIModel] {
        switch self {
        case .removeObject, .replaceBackground: return AIModel.qwenImageEdit2511
        case .upscale: return []
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
        case .removeObject: return Self.removeWorkflow
        case .replaceBackground: return Self.inpaintWorkflow
        case .upscale: return Self.upscaleWorkflow
        }
    }

    /// Remove Object: as the edit workflow, but the model's reference shows the painted area
    /// filled red. With the photo as is, Qwen redraws the object it was asked to remove.
    static let removeWorkflow = """
        {
          "1": {"class_type": "UnetLoaderGGUF", "_meta": {"title": "Atelier Edit Model"},
                "inputs": {"unet_name": "qwen-image-edit-2511-Q6_K.gguf"}},
          "2": {"class_type": "CLIPLoader", "_meta": {"title": "Atelier Text Encoder"},
                "inputs": {"clip_name": "qwen_2.5_vl_7b.safetensors", "type": "qwen_image", "device": "default"}},
          "3": {"class_type": "VAELoader", "inputs": {"vae_name": "qwen_image_vae.safetensors"}},
          "4": {"class_type": "LoraLoaderModelOnly", "_meta": {"title": "Atelier Speed LoRA"},
                "inputs": {"model": ["1", 0], "lora_name": "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors",
                           "strength_model": 1.0}},
          "5": {"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["4", 0], "shift": 3.1}},
          "6": {"class_type": "CFGNorm", "inputs": {"model": ["5", 0], "strength": 1.0}},
          "7": {"class_type": "LoadImage", "_meta": {"title": "Atelier Image"}, "inputs": {"image": "input.png"}},
          "8": {"class_type": "LoadImageMask", "_meta": {"title": "Atelier Mask"},
                "inputs": {"image": "mask.png", "channel": "red"}},
          "9": {"class_type": "TextEncodeQwenImageEditPlus", "_meta": {"title": "Atelier Prompt"},
                "inputs": {"prompt": "", "clip": ["2", 0], "image1": ["20", 0]}},
          "10": {"class_type": "TextEncodeQwenImageEditPlus", "_meta": {"title": "Atelier Negative Prompt"},
                 "inputs": {"prompt": "", "clip": ["2", 0], "image1": ["20", 0]}},
          "11": {"class_type": "FluxKontextMultiReferenceLatentMethod",
                 "inputs": {"conditioning": ["22", 0], "reference_latents_method": "index_timestep_zero"}},
          "12": {"class_type": "FluxKontextMultiReferenceLatentMethod",
                 "inputs": {"conditioning": ["23", 0], "reference_latents_method": "index_timestep_zero"}},
          "13": {"class_type": "VAEEncode", "inputs": {"pixels": ["7", 0], "vae": ["3", 0]}},
          "14": {"class_type": "SetLatentNoiseMask", "inputs": {"samples": ["13", 0], "mask": ["8", 0]}},
          "15": {"class_type": "KSampler", "_meta": {"title": "Atelier Sampler"},
                 "inputs": {"seed": 0, "steps": 4, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple",
                            "denoise": 1.0, "model": ["6", 0], "positive": ["11", 0], "negative": ["12", 0],
                            "latent_image": ["14", 0]}},
          "16": {"class_type": "VAEDecode", "inputs": {"samples": ["15", 0], "vae": ["3", 0]}},
          "17": {"class_type": "SaveImage", "_meta": {"title": "Atelier Output"},
                 "inputs": {"images": ["16", 0], "filename_prefix": "Atelier"}},
          "18": {"class_type": "GetImageSize", "inputs": {"image": ["7", 0]}},
          "19": {"class_type": "EmptyImage",
                 "inputs": {"width": ["18", 0], "height": ["18", 1], "batch_size": 1, "color": 16711680}},
          "20": {"class_type": "ImageCompositeMasked",
                 "inputs": {"destination": ["7", 0], "source": ["19", 0], "x": 0, "y": 0, "resize_source": false,
                            "mask": ["8", 0]}},
          "21": {"class_type": "VAEEncode", "inputs": {"pixels": ["20", 0], "vae": ["3", 0]}},
          "22": {"class_type": "ReferenceLatent", "inputs": {"conditioning": ["9", 0], "latent": ["21", 0]}},
          "23": {"class_type": "ReferenceLatent", "inputs": {"conditioning": ["10", 0], "latent": ["21", 0]}}
        }
        """

    /// Qwen-Image-Edit-2511 (GGUF, via ComfyUI-GGUF) with the 4-step Lightning LoRA. The photo is
    /// the edit reference; the mask limits which part of the latent is regenerated. The reference
    /// latent comes from ReferenceLatent at the generation size: Qwen's encoder would rescale it
    /// to about 1 megapixel, which doubles the work at 768 px.
    static let inpaintWorkflow = """
        {
          "1": {"class_type": "UnetLoaderGGUF", "_meta": {"title": "Atelier Edit Model"},
                "inputs": {"unet_name": "qwen-image-edit-2511-Q6_K.gguf"}},
          "2": {"class_type": "CLIPLoader", "_meta": {"title": "Atelier Text Encoder"},
                "inputs": {"clip_name": "qwen_2.5_vl_7b.safetensors", "type": "qwen_image", "device": "default"}},
          "3": {"class_type": "VAELoader", "inputs": {"vae_name": "qwen_image_vae.safetensors"}},
          "4": {"class_type": "LoraLoaderModelOnly", "_meta": {"title": "Atelier Speed LoRA"},
                "inputs": {"model": ["1", 0], "lora_name": "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors",
                           "strength_model": 1.0}},
          "5": {"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["4", 0], "shift": 3.1}},
          "6": {"class_type": "CFGNorm", "inputs": {"model": ["5", 0], "strength": 1.0}},
          "7": {"class_type": "LoadImage", "_meta": {"title": "Atelier Image"}, "inputs": {"image": "input.png"}},
          "8": {"class_type": "LoadImageMask", "_meta": {"title": "Atelier Mask"},
                "inputs": {"image": "mask.png", "channel": "red"}},
          "9": {"class_type": "TextEncodeQwenImageEditPlus", "_meta": {"title": "Atelier Prompt"},
                "inputs": {"prompt": "", "clip": ["2", 0], "image1": ["7", 0]}},
          "10": {"class_type": "TextEncodeQwenImageEditPlus", "_meta": {"title": "Atelier Negative Prompt"},
                 "inputs": {"prompt": "", "clip": ["2", 0], "image1": ["7", 0]}},
          "11": {"class_type": "FluxKontextMultiReferenceLatentMethod",
                 "inputs": {"conditioning": ["22", 0], "reference_latents_method": "index_timestep_zero"}},
          "12": {"class_type": "FluxKontextMultiReferenceLatentMethod",
                 "inputs": {"conditioning": ["23", 0], "reference_latents_method": "index_timestep_zero"}},
          "13": {"class_type": "VAEEncode", "inputs": {"pixels": ["7", 0], "vae": ["3", 0]}},
          "14": {"class_type": "SetLatentNoiseMask", "inputs": {"samples": ["13", 0], "mask": ["8", 0]}},
          "15": {"class_type": "KSampler", "_meta": {"title": "Atelier Sampler"},
                 "inputs": {"seed": 0, "steps": 4, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple",
                            "denoise": 1.0, "model": ["6", 0], "positive": ["11", 0], "negative": ["12", 0],
                            "latent_image": ["14", 0]}},
          "16": {"class_type": "VAEDecode", "inputs": {"samples": ["15", 0], "vae": ["3", 0]}},
          "17": {"class_type": "SaveImage", "_meta": {"title": "Atelier Output"},
                 "inputs": {"images": ["16", 0], "filename_prefix": "Atelier"}},
          "22": {"class_type": "ReferenceLatent", "inputs": {"conditioning": ["9", 0], "latent": ["13", 0]}},
          "23": {"class_type": "ReferenceLatent", "inputs": {"conditioning": ["10", 0], "latent": ["13", 0]}}
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
    /// A value whose input the node doesn't have is skipped, so one binding can offer
    /// alternatives (a prompt is `text` on CLIPTextEncode and `prompt` on Qwen's encoder).
    public static func bind(_ graph: [String: Any], values: [String: [String: Any]],
                            required: Set<String> = []) throws -> [String: Any] {
        var graph = graph
        var found: Set<String> = []
        for (id, value) in graph {
            guard var node = value as? [String: Any],
                  let title = (node["_meta"] as? [String: Any])?["title"] as? String,
                  let inputs = values[title] else { continue }
            var nodeInputs = node["inputs"] as? [String: Any] ?? [:]
            for (key, input) in inputs where nodeInputs[key] != nil { nodeInputs[key] = input }
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

/// A model a workflow loads, and what its license allows. Prep for the model registry and
/// the license gate on export.
public struct AIModel: Codable, Hashable, Sendable {
    public enum AllowedUse: String, Codable, Sendable { case commercial, personal, research, unknown }

    public var name: String
    public var file: String
    public var license: String
    public var allowedUse: AllowedUse
    public var source: URL?

    public init(name: String, file: String, license: String, allowedUse: AllowedUse, source: URL? = nil) {
        self.name = name
        self.file = file
        self.license = license
        self.allowedUse = allowedUse
        self.source = source
    }

    /// What the built-in edit workflow loads. All Apache 2.0, so results may go to the website or shop.
    public static let qwenImageEdit2511: [AIModel] = [
        AIModel(name: "Qwen-Image-Edit-2511 (Q6_K GGUF)", file: "qwen-image-edit-2511-Q6_K.gguf",
                license: "Apache-2.0", allowedUse: .commercial,
                source: URL(string: "https://huggingface.co/unsloth/Qwen-Image-Edit-2511-GGUF")),
        AIModel(name: "Qwen2.5-VL 7B text encoder", file: "qwen_2.5_vl_7b.safetensors",
                license: "Apache-2.0", allowedUse: .commercial,
                source: URL(string: "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI")),
        AIModel(name: "Qwen-Image VAE", file: "qwen_image_vae.safetensors",
                license: "Apache-2.0", allowedUse: .commercial,
                source: URL(string: "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI")),
        AIModel(name: "Qwen-Image-Edit-2511 Lightning 4-step LoRA",
                file: "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors",
                license: "Apache-2.0", allowedUse: .commercial,
                source: URL(string: "https://huggingface.co/lightx2v/Qwen-Image-Edit-2511-Lightning")),
    ]
}
