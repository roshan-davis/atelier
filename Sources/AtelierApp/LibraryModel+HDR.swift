import AppKit
import AtelierCore

/// HDR mode's place in the library window: opening it on a photo, and asking before unsaved
/// HDR changes would be left behind (another photo, another mode, quitting).
extension LibraryModel {
    /// Develop and HDR have panels of sliders: Tab, ⌃Tab and the arrow keys move through them.
    var usesPanelKeys: Bool { mode == .develop || mode == .hdr }

    /// Photo > HDR… (⌃H) and the photo menus: HDR on the one target photo.
    func openHDR() {
        guard targetIDs.count == 1, let id = targetIDs.first else { return }
        if !selection.contains(id) { selection = [id] }
        // Already in HDR: the focus change opens it, after asking about unsaved changes.
        if focusedID != id { focusedID = id }
        if mode != .hdr { mode = .hdr }
    }

    /// Done (and Esc): back to the view HDR was opened from, asking first about unsaved changes.
    func closeHDR() {
        guard mode == .hdr else { return }
        mode = hdrReturnMode == .hdr ? .grid : hdrReturnMode
    }

    /// Asks before leaving unsaved HDR changes for another mode.
    func leaveHDR(to newValue: ViewMode) {
        hdr.confirmLeaving(proceed: { [weak self] in
            self?.setModeConfirmed(newValue)
        }, stay: { [weak self] in
            // The toolbar's mode buttons already show the new mode: put them back.
            self?.objectWillChange.send()
        })
    }

    /// Another photo became the focused one while HDR is open (the Filmstrip, arrow keys).
    func hdrFocusChanged(from previous: Int64?) {
        guard !hdrRevertingFocus else { return }
        let target = focusedID
        if target != nil, target == hdr.assetID || target == hdr.resultAssetID { return }
        guard hdr.dirty || hdr.busy else { hdr.open(target); return }
        hdr.confirmLeaving(proceed: { [weak self] in
            guard let self, self.focusedID == target, self.mode == .hdr else { return }
            self.hdr.open(target)
        }, stay: { [weak self] in
            // After this focus change has finished, so it isn't undone from inside its own update.
            DispatchQueue.main.async {
                guard let self, self.focusedID == target else { return }
                self.hdrRevertingFocus = true
                self.focusedID = previous
                self.selection = previous.map { [$0] } ?? []
                self.hdrRevertingFocus = false
            }
        })
    }

    /// Quitting with unsaved HDR changes: Save, Don't Save or Cancel. Returns whether to quit now;
    /// otherwise `reply` answers once the question is.
    func shouldTerminateWithHDR(reply: @escaping (Bool) -> Void) -> Bool {
        guard mode == .hdr, hdr.dirty || hdr.busy else { return true }
        let canCancel = mainWindow?.isVisible == true
        if hdr.busy, !canCancel { hdr.cancel(); return true }
        // A plain dialog rather than a sheet: Atelier is already waiting to quit.
        hdr.confirmLeaving(canCancel: canCancel, asSheet: false, proceed: { reply(true) }, stay: { reply(false) })
        return false
    }
}
