import AppKit
import AtelierCore
import Foundation

/// State for the AI tool in Develop: the chosen recipe, the brush mask, and the running job.
@MainActor
final class AIController: ObservableObject {
    enum ServerStatus: Equatable {
        case unknown, checking
        case connected(String)
        case unreachable(String)
    }

    @Published var recipe: AIRecipe = .removeObject {
        didSet { if recipe != oldValue { recipeChanged() } }
    }
    @Published var strokes: [BrushStroke] = []
    /// Brush radius as a fraction of the photo's width.
    @Published var brushSize = 0.03
    @Published var erasing = false
    @Published var prompt = ""
    /// The area Replace Background regenerates, on the proxy, for the overlay.
    @Published private(set) var backgroundMask: CGImage?
    @Published private(set) var isFindingSubject = false
    @Published private(set) var phase: String?
    /// How far ComfyUI has got, 0...1, while it reports it.
    @Published private(set) var fraction: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var serverStatus: ServerStatus = .unknown

    var isRunning: Bool { task != nil }
    private var isCancelling: Bool { task?.isCancelled ?? false }
    private var task: Task<Void, Never>?
    weak var model: LibraryModel?

    /// Settings > AI, as the runner needs them.
    static var settings: AISettings {
        let defaults = UserDefaults.standard
        let server = defaults.string(forKey: "ai.server").flatMap(URL.init(string:)) ?? AISettings.defaultServer
        let size = defaults.integer(forKey: "ai.generationSize")
        let factor = defaults.integer(forKey: "ai.upscaleFactor")
        return AISettings(server: server,
                          editModel: defaults.string(forKey: "ai.editModel")?.nilIfEmpty,
                          upscaleModel: defaults.string(forKey: "ai.upscaleModel")?.nilIfEmpty,
                          generationSize: size > 0 ? size : 1024,
                          upscaleFactor: factor > 0 ? factor : 2)
    }

    var canGenerate: Bool {
        guard !isRunning else { return false }
        switch recipe {
        case .removeObject: return strokes.contains { !$0.erases }
        case .replaceBackground: return !prompt.trimmingCharacters(in: .whitespaces).isEmpty
        case .upscale: return true
        }
    }

    /// A new photo was opened: start over.
    func reset() {
        strokes = []
        backgroundMask = nil
        errorMessage = nil
        if recipe == .replaceBackground { findSubject() }
    }

    func clearMask() { strokes = [] }

    private func recipeChanged() {
        errorMessage = nil
        if recipe.usesPrompt, prompt.isEmpty || AIRecipe.allCases.contains(where: { $0.defaultPrompt == prompt && !prompt.isEmpty }) {
            prompt = recipe.defaultPrompt
        }
        if recipe == .replaceBackground { findSubject() }
    }

    /// Finds the subject on the proxy so the panel can show what stays.
    func findSubject() {
        guard let image = model?.develop.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        isFindingSubject = true
        Task.detached(priority: .userInitiated) {
            let mask = (try? AIImaging.subjectMask(for: image)).flatMap(AIImaging.inverted)
            await MainActor.run {
                self.isFindingSubject = false
                self.backgroundMask = mask
                if mask == nil { self.errorMessage = "Lightfast couldn't find a subject in this photo." }
            }
        }
    }

    func checkServer() {
        let settings = Self.settings
        serverStatus = .checking
        Task {
            do {
                let version = try await ComfyClient(baseURL: settings.server).ping()
                serverStatus = .connected(version)
            } catch {
                serverStatus = .unreachable(error.localizedDescription)
            }
        }
    }

    /// Runs the recipe on the open photo. The result is a new photo stacked on it, which then opens.
    func generate() {
        guard let model, let id = model.develop.assetID, canGenerate else { return }
        model.develop.flushSave()
        errorMessage = nil
        phase = "Starting"
        fraction = nil
        let request = AIRequest(recipe: recipe, prompt: recipe.usesPrompt ? prompt : "", strokes: strokes)
        let settings = Self.settings
        let runner = AIRunner(catalog: model.catalog, client: ComfyClient(baseURL: settings.server))
        let recipe = self.recipe
        task = Task.detached {
            do {
                let result = try await runner.run(request, on: id, settings: settings) { progress in
                    Task { @MainActor in
                        guard self.task != nil, !self.isCancelling else { return }
                        self.phase = progress.phase
                        self.fraction = progress.fraction
                    }
                }
                await MainActor.run {
                    self.finish()
                    self.strokes = []
                    self.serverStatus = .connected(self.serverVersion ?? "connected")
                    model.previewScheduler.request(.thumbnail, for: result.assetID, source: result.url, urgent: true)
                    model.previewScheduler.request(.preview, for: result.assetID, source: result.url)
                    model.selection = [result.assetID]
                    model.focusedID = result.assetID
                    model.status = "\(recipe.title) finished. The result is stacked next to the original."
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finish()
                    model.status = "\(recipe.title) cancelled"
                }
            } catch {
                await MainActor.run {
                    self.finish()
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var serverVersion: String? {
        if case .connected(let version) = serverStatus { return version }
        return nil
    }

    func cancel() {
        task?.cancel()
        phase = "Cancelling…"
        fraction = nil
    }

    private func finish() {
        task = nil
        phase = nil
        fraction = nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension LibraryModel {
    /// Photo > Remove Object… and the like: Develop with the AI tool on that recipe.
    func openAI(_ recipe: AIRecipe) {
        guard focusedID != nil else { return }
        openDevelop()
        develop.isAIOpen = true
        ai.recipe = recipe
    }
}
