import AppKit
import AtelierCore

/// The Lens Blur mode's place in the library window (AT-074): opening it on a photo, Save, and
/// closing it. The mode is Develop's photo view with Lens Blur's controls in place of the
/// panels (`DevelopController.isLensBlurring`); Save renders the blur at full size into a TIFF
/// stacked on the original (`LensBlurPhoto`), which is what the rest of Atelier shows.
extension LibraryModel {
    /// Photo > Lens Blur… and the photo menus: the one target photo in the Lens Blur mode. On a
    /// Lens Blur photo it opens the original it was made from, whose settings hold the blur, so
    /// the blur can be changed and saved again.
    func openLensBlur() {
        guard targetIDs.count == 1, let target = targetIDs.first else { return }
        let photo = (try? LensBlurPhoto.source(of: target, catalog: catalog)) ?? target
        if !selection.contains(photo) { selection = [photo] }
        if focusedID != photo { focusedID = photo }
        if mode != .develop { mode = .develop }
        // Not while HDR asks about unsaved changes first: the mode is still HDR then.
        guard mode == .develop else { return }
        develop.isLensBlurring = true
    }

    /// Cancel (and Esc): back to Develop, with every change made in the mode undone; only Save
    /// keeps them (and makes or updates the Lens Blur photo). Not while Save is rendering.
    func closeLensBlur() {
        guard !develop.lensBlurSaving else { return }
        develop.isLensBlurring = false
    }

    /// File > Save Lens Blur Photo (⌘S) and the panel's Save: renders the open photo's Lens Blur
    /// at full size off the main thread, stacks the TIFF on the photo (or replaces the one
    /// saved before), then closes the mode on the Lens Blur photo, which opens in Develop.
    func saveLensBlur() {
        guard develop.isLensBlurring, let source = develop.assetID, !develop.lensBlurSaving else { return }
        // The save renders the catalog's settings, so the last drag must be in it.
        develop.flushSave()
        develop.lensBlurSaving = true
        develop.lensBlurSaveError = nil
        status = "Saving the Lens Blur photo…"
        let catalog = self.catalog
        let importer = Importer(catalog: catalog, previews: nil, scheduler: previewScheduler)
        Task.detached(priority: .userInitiated) {
            let result = Result { try LensBlurPhoto.save(source, catalog: catalog, importer: importer) }
            await MainActor.run { self.finishLensBlurSave(result, source: source) }
        }
    }

    private func finishLensBlurSave(_ result: Result<LensBlurPhoto.Saved, Error>, source: Int64) {
        develop.lensBlurSaving = false
        switch result {
        case .failure(let error):
            develop.lensBlurSaveError = error.localizedDescription
            status = "The Lens Blur photo could not be saved"
        case .success(let saved):
            if saved.isNew {
                previewScheduler.request(.thumbnail, for: saved.id, source: saved.url, urgent: true)
                previewScheduler.request(.preview, for: saved.id, source: saved.url)
            } else {
                // New pixels under the Lens Blur photo's own edits: its previews and any open copy.
                editedFileChanged(saved.id)
            }
            if develop.assetID == source {
                develop.keepLensBlurChanges()
                develop.loadLensBlurPhoto()
            }
            status = saved.isNew ? "Saved the Lens Blur photo, stacked on the original"
                : "Updated the Lens Blur photo"
            // Done here: on to the new photo, as Edit In and HDR bring back theirs. Not if
            // another photo or mode was chosen while it rendered.
            guard mode == .develop, develop.isLensBlurring, develop.assetID == source else { return }
            develop.isLensBlurring = false
            selection = [saved.id]
            focusedID = saved.id
        }
    }
}
