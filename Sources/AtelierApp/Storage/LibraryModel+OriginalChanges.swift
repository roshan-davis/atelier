import AtelierCore
import Foundation

/// The When the original changed sheet's subject (AT-079c part 3): the photos a command (Export,
/// Edit In) stopped for, each with a choice, and how to run the command again on the ones the
/// person lets through.
struct ChangedOriginalsReview: Identifiable {
    enum Choice: Hashable {
        case useNewFile, useKeptCopy, skip
    }

    struct Item: Identifiable {
        let change: OriginalChangedError
        var choice: Choice = .useNewFile
        var id: Int64 { change.assetID }
    }

    let id = UUID()
    /// "export", "Edit In Photoshop": what the sheet's message says carried on.
    let command: String
    var items: [Item]
    /// Runs the command again on these photo ids.
    let retry: @MainActor ([Int64]) -> Void

    /// "3 photos changed on megham since they were imported"
    var title: String {
        let places = Array(Set(items.map(\.change.place))).sorted().formatted(.list(type: .and))
        return items.count == 1
            ? "\(items[0].change.filename) changed on \(places) since it was imported"
            : "\(items.count) photos changed on \(places) since they were imported"
    }
}

extension LibraryModel {
    /// Shows the sheet for the photos a command stopped for.
    func reviewChangedOriginals(_ changes: [OriginalChangedError], command: String,
                                retry: @escaping @MainActor ([Int64]) -> Void) {
        guard !changes.isEmpty else { return }
        changedOriginals = ChangedOriginalsReview(command: command, items: changes.map { .init(change: $0) }, retry: retry)
    }

    /// The sheet's Continue: Use the New File reads each new file (the catalog takes it), Use the
    /// Kept Copy runs from the copy on this Mac, Skip leaves the photo; then the command runs again
    /// on the photos let through.
    func applyChangedOriginals(_ review: ChangedOriginalsReview) {
        changedOriginals = nil
        let newFiles = review.items.filter { $0.choice == .useNewFile }.map(\.change)
        var through = review.items.filter { $0.choice == .useKeptCopy }.compactMap { item -> Int64? in
            guard let originals, (try? catalog.useKeptCopy(item.change.assetID, cache: originals)) != nil else { return nil }
            return item.change.assetID
        }
        Task {
            through += await useNewOriginals(newFiles)
            if !through.isEmpty { review.retry(through) }
        }
    }

    /// Use the New File, for Develop's banner and the sheet: reads each new file once into the cache
    /// (still kept if it was), with progress and Cancel in the status bar; the catalog takes its
    /// hash, and the previews and the open photo are made again from it. Edits stay. Returns the
    /// photos that now use their new file.
    @discardableResult
    func useNewOriginals(_ changes: [OriginalChangedError]) async -> [Int64] {
        let catalog = self.catalog
        let originals = self.originals
        var accepted: [Int64] = []
        var problems: [String] = []
        for change in changes {
            let phase = "Reading the new \(change.filename) from \(change.place)…"
            downloadProgress = ImportStatus(phase: phase, fraction: nil)
            let total = (try? catalog.originalChange(for: change.fileID))?.newSize ?? 0
            let relay = ProgressRelay { [weak self] copied in
                guard let self, total > 0, self.downloadProgress?.phase == phase else { return }
                self.downloadProgress = ImportStatus(phase: phase, fraction: min(1, Double(copied) / Double(total)))
            }
            let task = Task.detached(priority: .userInitiated) {
                try catalog.useNewOriginal(change.assetID, cache: originals, progress: { relay.send($0) })
            }
            newOriginalTask = task
            let result = await task.result
            newOriginalTask = nil
            downloadProgress = nil
            switch result {
            case .success:
                accepted.append(change.assetID)
                newOriginalArrived(change)
            case .failure(is CancellationError):
                status = "Stopped reading \(change.filename); it still uses the file imported."
                return accepted
            case .failure(let error):
                problems.append(error.localizedDescription)
            }
        }
        if let problem = problems.first {
            status = problem
        } else if accepted.count == 1, let change = changes.first {
            status = "\(change.filename) now uses the new file on \(change.place). Its edits stay."
        } else if !accepted.isEmpty {
            status = "\(accepted.count) photos now use their new files. Their edits stay."
        }
        return accepted
    }

    /// Develop's Use the Kept Copy: the photo opens from the copy kept on this Mac and stays marked.
    func useKeptOriginal(_ change: OriginalChangedError) {
        guard let originals, (try? catalog.useKeptCopy(change.assetID, cache: originals)) != nil else {
            status = "The copy kept on this Mac is gone. Use the new file, or leave the photo for now."
            return
        }
        develop.sourceChanged(change.assetID)
        status = "Editing the copy of \(change.filename) kept on this Mac; the newer file on \(change.place) isn't used."
    }

    /// The new file is the photo's now: previews are rebuilt and the open photo reopens from it.
    private func newOriginalArrived(_ change: OriginalChangedError) {
        for id in Set([change.assetID, change.fileID]) {
            previewScheduler.retryFailed(for: id)
            develop.refreshPreviews(for: id, settings: (try? catalog.developSettings(for: id)) ?? .neutral)
            develop.sourceChanged(id)
            if focusedID == id { reloadDetail() }
        }
    }
}
