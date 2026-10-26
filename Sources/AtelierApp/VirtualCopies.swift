import AppKit
import AtelierCore

extension LibraryModel {
    /// Photo > Create Virtual Copy (⌘'): one copy of each target photo, sharing its file but
    /// with edits of its own. The copies are selected afterwards.
    func createVirtualCopies() {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        develop.flushSave()
        var copies: [Int64] = []
        for id in ids {
            do {
                let copy = try catalog.createVirtualCopy(of: id)
                // Same settings, same look: the copy starts with the photo's previews.
                for size in PreviewCache.Size.allCases where previews.has(size, for: id) {
                    let target = previews.url(for: copy, size: size)
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.copyItem(at: previews.url(for: id, size: size), to: target)
                }
                copies.append(copy)
            } catch {
                status = error.localizedDescription
            }
        }
        guard let first = copies.first else { return }
        selection = Set(copies)
        focusedID = first
        status = copies.count == 1
            ? "Created \((try? catalog.virtualCopyName(of: first)) ?? "a virtual copy"). Edit it without changing the original."
            : "Created \(copies.count) virtual copies"
    }

    /// Photo > Remove Virtual Copy: asks first, since the copy's edits go with it. The original
    /// photo and its file are never touched.
    func removeVirtualCopies() {
        let copies = targetIDs.filter { id in rows.first { $0.id == id }?.stackKind == .virtualCopy }
        guard !copies.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = copies.count == 1
            ? "Remove \(virtualCopyName(copies[0]) ?? "this virtual copy")?"
            : "Remove \(copies.count) virtual copies?"
        alert.informativeText = "Their develop settings, ratings and keywords are removed from the catalog. The original photo and its file stay as they are."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if copies.contains(develop.assetID ?? -1) { develop.flushSave() }
        do {
            let removed = try catalog.removeVirtualCopies(copies)
            for id in copies { previews.remove(for: id) }
            status = "Removed \(removed) virtual cop\(removed == 1 ? "y" : "ies")"
        } catch {
            status = error.localizedDescription
        }
    }

    /// "Copy 2" when the photo is a virtual copy.
    func virtualCopyName(_ id: Int64?) -> String? {
        guard let id, let row = rows.first(where: { $0.id == id }), row.stackKind == .virtualCopy else { return nil }
        return row.stackName
    }

    var targetsIncludeVirtualCopy: Bool {
        targetIDs.contains { id in rows.first { $0.id == id }?.stackKind == .virtualCopy }
    }
}
