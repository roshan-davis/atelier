import AppKit
import AtelierCore
import AtelierHDRCore

/// HDR's Presets panel (Rosh, Nov 12, 2026: "Machinery HDR gives great presets on the left
/// panels with thumbnail previews"): apply, preview on the photo, the thumbnails, and the user's
/// own presets. Presets keep the photo's Exposure (`HDRPreset.applied(to:)`).
extension HDRController {
    /// Click: the preset's look, as one undo step.
    func applyPreset(_ preset: HDRPreset) {
        guard hasPhoto, !busy else { return }
        let old = settings
        previewSettings = nil
        settings = preset.applied(to: settings)
        recordStep(from: old)
        changed()
        model?.status = "Applied the HDR preset \(preset.name)"
    }

    /// The pointer resting on a preset shows its look on the photo; nil puts the settings back.
    func previewPreset(_ preset: HDRPreset?) {
        guard hasPhoto, !busy else { return }
        let next = preset.map { $0.applied(to: settings) }
        guard next != previewSettings else { return }
        // Resting on the preset already applied changes nothing on the photo.
        previewSettings = next == settings ? nil : next
        render()
    }

    /// Save Preset…: the current look under `name`, in User Presets.
    func savePreset(named name: String) {
        let preset = HDRPreset(name: name, settings: settings)
        presetFileChange { try presetStore.save(preset) }
    }

    func renamePreset(_ preset: HDRPreset, to name: String) {
        guard !preset.isBuiltIn else { return }
        presetFileChange { try presetStore.rename(preset.id, to: name) }
    }

    func deletePreset(_ preset: HDRPreset) {
        guard !preset.isBuiltIn else { return }
        if presetFileChange({ try presetStore.delete(preset.id) }) { DeleteFeedback.play(.remove) }
    }

    /// Runs a change to the presets file, then reloads the list. False (with an error shown) if it failed.
    @discardableResult
    private func presetFileChange(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            presets = presetStore.all()
            updatePresetThumbnails()
            return true
        } catch {
            self.error = "The HDR presets couldn't be saved: \(error.localizedDescription)"
            return false
        }
    }

    /// Remakes the thumbnails when the photo, its Exposure or the presets changed: every preset
    /// rendered on a 200 px copy of the photo, sharing one exposure analysis (presets don't change
    /// Exposure). One set is made at a time; a drag meanwhile is followed by one for its latest value.
    func updatePresetThumbnails() {
        guard let proxy = proxyInput else { presetThumbnails = [:]; thumbnailsShown = nil; return }
        let key = ThumbnailsKey(token: currentInputToken, exposure: settings.exposure, presets: presets)
        guard key != thumbnailsShown, thumbnailsTask == nil else { return }
        let io = thumbnailIO, current = settings
        thumbnailsTask = Task {
            let made = try? await Task.detached(priority: .utility) { () -> [UUID: CGImage] in
                let small = try HDRToneMapper.shrink(proxy, longEdge: 200)
                let analysis = try HDRToneMapper.analyze(small, exposure: key.exposure)
                var result: [UUID: CGImage] = [:]
                for preset in key.presets {
                    try Task.checkCancellation()
                    let rendered = try HDRToneMapper.render(small, settings: preset.applied(to: current), analysis: analysis)
                    result[preset.id] = try io.preview(rendered)
                }
                return result
            }.value
            thumbnailsTask = nil
            if key.token == currentInputToken {
                presetThumbnails = (made ?? [:]).mapValues { NSImage(cgImage: $0, size: .zero) }
                thumbnailsShown = key
            }
            updatePresetThumbnails()
        }
    }
}
