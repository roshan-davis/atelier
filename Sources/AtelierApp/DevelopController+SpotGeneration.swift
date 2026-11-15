import AppKit
import AtelierCore
import Foundation

/// The Remove tool's Generative AI (AT-066 step 4): a Content-Aware spot whose fill comes from
/// the Remove Object recipe in ComfyUI (Settings > AI). While ComfyUI works the spot shows the
/// Content-Aware fill; the panel shows progress and Cancel. The result is the spot's patch,
/// recorded as one history step, "Generative Fill".
extension DevelopController {
    /// The panel's Generative AI switch: for new Content-Aware spots, and the selected one.
    func setSpotGenerative(_ on: Bool) {
        spotGenerative = on
        guard let spot = selectedSpot, spot.mode == .contentAware, spot.generative != on else { return }
        updateSpot(spot.id, step: on ? "Generative AI On" : "Generative AI Off") { $0.generative = on }
        if on, spot.patch == nil { generateFill(for: spot.id) } else if !on { cancelFill(for: spot.id) }
    }

    var isGeneratingSelectedSpot: Bool { selectedSpotID.map { spotGenerations[$0] != nil } ?? false }

    /// Makes a new fill for spot `id` of the open photo with a new seed. The spot keeps its
    /// current fill until the new one is in.
    func generateFill(for id: UUID) {
        guard let assetID, let spot = settings.spots.first(where: { $0.id == id }), spot.generative,
              let url = try? catalog.fileURL(for: assetID) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            spotGenerationError = "The original is offline. Connect its drive and try again."
            return
        }
        cancelFill(for: id)
        spotGenerationError = nil
        spotGenerations[id] = AIProgress("Rendering the photo")
        let settings = self.settings
        let ai = AIController.settings
        let runner = AIRunner(catalog: catalog, client: ComfyClient(baseURL: ai.server))
        let seed = UInt32.random(in: 0...UInt32.max)
        let report: @Sendable (AIProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.spotGenerations[id] != nil else { return }
                self.spotGenerations[id] = progress
            }
        }
        spotGenerationTasks[id] = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // The photo at full size, with the spots before this one, as the model sees it.
                guard let session = DevelopRenderer.shared.session(for: url, maxPixelSize: nil),
                      let input = session.spotGenerationInput(for: id, settings: settings) else {
                    throw AIError("The photo could not be rendered.")
                }
                try Task.checkCancellation()
                let patch = try await runner.generateFill(input, seed: seed, settings: ai, progress: report)
                try Task.checkCancellation()
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.finishFill(patch, for: id, on: assetID)
                }
            } catch {
                // A cancelled job was already cleared, and a new one may have taken its place.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await MainActor.run {
                    self?.endFill(id)
                    self?.spotGenerationError = "Generative AI: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Stops making spot `id`'s fill (the panel's Cancel, or the spot was deleted).
    func cancelFill(for id: UUID) {
        spotGenerationTasks[id]?.cancel()
        endFill(id)
    }

    func cancelSelectedFill() {
        if let id = selectedSpotID { cancelFill(for: id) }
    }

    private func endFill(_ id: UUID) {
        spotGenerationTasks[id] = nil
        spotGenerations[id] = nil
    }

    /// Puts a finished fill on its spot: on the open photo as a history step, or, if another
    /// photo is open by now, into that photo's saved settings.
    private func finishFill(_ patch: DevelopSettings.Spot.Patch, for id: UUID, on photo: Int64) {
        endFill(id)
        let step = "Generative Fill"
        if photo == assetID {
            guard settings.spots.contains(where: { $0.id == id && $0.generative }) else { return }
            updateSpot(id, step: step) { $0.patch = patch }
            return
        }
        guard var saved = try? catalog.developSettings(for: photo),
              saved.spots.contains(where: { $0.id == id && $0.generative }) else { return }
        var history = (try? catalog.developHistory(for: photo)) ?? DevelopHistory()
        let previous = saved
        guard let index = saved.spots.firstIndex(where: { $0.id == id }) else { return }
        saved.spots[index].patch = patch
        history.record(step, settings: saved, previous: previous)
        try? catalog.saveDevelop(saved, history: history, for: photo)
    }

    /// A spot's points or size changed: its generated fill no longer fits, so a new one is made
    /// once the drag or slider has been still a moment (the spot shows Content-Aware meanwhile).
    func spotGeometryChanged(_ id: UUID) {
        guard let spot = settings.spots.first(where: { $0.id == id }), spot.mode == .contentAware,
              spot.generative else { return }
        cancelFill(for: id)
        spotGenerationTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.generateFill(for: id)
        }
    }
}
