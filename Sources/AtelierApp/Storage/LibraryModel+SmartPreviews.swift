import AtelierCore
import Foundation

/// Library > Previews > Build Smart Previews and Discard Smart Previews (AT-079d), Lightroom's
/// names. Building reads each original once (a share's through the cache of originals, hash
/// checked), in the background behind the photo being opened, with progress and Cancel.
extension LibraryModel {
    /// `quiet`: made by themselves (after an import into a location that makes them), so nothing
    /// is said unless some were made or failed. A request while a run is going waits for it.
    func buildSmartPreviews(_ ids: [Int64], quiet: Bool = false) {
        guard let store = smartPreviews, !ids.isEmpty else { return }
        guard smartPreviewJob == nil else {
            pendingSmartPreviews += ids
            return
        }
        let catalog = self.catalog
        let originals = self.originals
        let paused = foregroundReading
        smartPreviewJob = Task { [weak self] in
            // Masters only, and only those without one: virtual copies share their master's.
            let files = await Task.detached(priority: .utility) { () -> [Int64] in
                var seen = Set<Int64>()
                return ids.compactMap { id in
                    let file = (try? catalog.originalID(for: id)) ?? id
                    return seen.insert(file).inserted && !store.has(file) ? file : nil
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            guard !files.isEmpty else {
                self.smartPreviewJob = nil
                if !quiet {
                    self.status = ids.count == 1 ? "This photo already has a smart preview." : "These photos already have smart previews."
                }
                self.buildPendingSmartPreviews()
                return
            }
            let count = files.count
            let phase = { (done: Int) in "Building smart previews · \(min(done + 1, count)) of \(count)" }
            self.smartPreviewProgress = ImportStatus(phase: phase(0), fraction: 0)
            let relay = ProgressRelay { [weak self] done in
                guard let self, self.smartPreviewProgress != nil else { return }
                self.smartPreviewProgress = ImportStatus(phase: phase(Int(done)), fraction: Double(done) / Double(count))
            }
            let run = Task.detached(priority: .utility) { () -> SmartPreviewOutcome in
                Self.runSmartPreviews(files, catalog: catalog, store: store, originals: originals, paused: paused) {
                    relay.send(Int64($0))
                }
            }
            let outcome = await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
            self.smartPreviewProgress = nil
            self.smartPreviewJob = nil
            if !quiet || outcome.made > 0 || !outcome.failed.isEmpty {
                self.status = outcome.summary
                self.problemsTitle = "Smart previews not built"
                self.problems = outcome.failed
            }
            if !outcome.cancelled { self.buildPendingSmartPreviews() }
        }
    }

    private func buildPendingSmartPreviews() {
        guard !pendingSmartPreviews.isEmpty else { return }
        let next = pendingSmartPreviews
        pendingSmartPreviews = []
        buildSmartPreviews(next, quiet: true)
    }

    /// After an import: the new photos in locations with "Make smart previews for photos here".
    func buildSmartPreviewsAfterImport(_ ids: [Int64]) {
        guard smartPreviews != nil, !ids.isEmpty else { return }
        let catalog = self.catalog
        Task { [weak self] in
            let candidates = await Task.detached(priority: .utility) {
                (try? catalog.smartPreviewCandidates(among: ids)) ?? []
            }.value
            self?.buildSmartPreviews(candidates, quiet: true)
        }
    }

    /// The status bar's Cancel: stops after the photo being made; those made stay.
    func cancelSmartPreviews() {
        pendingSmartPreviews = []
        smartPreviewJob?.cancel()
        smartPreviewJob = nil
        smartPreviewProgress = nil
    }

    func discardSmartPreviews(_ ids: [Int64]) {
        guard let store = smartPreviews else { return }
        var seen = Set<Int64>()
        let files = ids.compactMap { id -> Int64? in
            let file = (try? catalog.originalID(for: id)) ?? id
            return seen.insert(file).inserted ? file : nil
        }
        let removed = store.discard(files)
        if removed > 0 { DeleteFeedback.play(.remove) }
        status = removed == 0 ? "No smart previews to discard."
            : "Discarded \(removed == 1 ? "1 smart preview" : "\(removed.formatted()) smart previews"). The originals and edits are unchanged."
    }

    /// Settings > Storage > Discard All: every smart preview but the one Develop is editing.
    func discardAllSmartPreviews() async -> Int {
        guard let store = smartPreviews else { return 0 }
        cancelSmartPreviews()
        let open = develop.editsSmartPreview ? develop.assetID.flatMap { try? catalog.originalID(for: $0) } : nil
        let removed = await Task.detached(priority: .userInitiated) { store.discardAll(sparing: open) }.value
        if removed > 0 { DeleteFeedback.play(.remove) }
        return removed
    }

    nonisolated private static func runSmartPreviews(_ files: [Int64], catalog: Catalog, store: SmartPreviewStore,
                                                     originals: OriginalCache?, paused: LockedValue<Bool>,
                                                     progress: @escaping @Sendable (Int) -> Void) -> SmartPreviewOutcome {
        var outcome = SmartPreviewOutcome()
        for (index, file) in files.enumerated() {
            // Behind the photo being opened, which reads first.
            while paused.value, !Task.isCancelled { Thread.sleep(forTimeInterval: 0.1) }
            if Task.isCancelled { outcome.cancelled = true; break }
            let name = (try? catalog.detail(for: file))?.asset.filename ?? "Photo \(file)"
            do {
                let source = try catalog.checkedSource(for: file, cache: originals)
                if CloudFiles.needsDownload(source.url) { outcome.notDownloaded += 1; continue }
                let match = DevelopRenderer.shared.cameraMatch(for: source.url)
                try store.make(file, from: source.url, cameraMatch: match, shouldStop: { Task.isCancelled })
                outcome.made += 1
            } catch let change as OriginalChangedError {
                outcome.failed.append(Problem(name: change.filename, reason: change.localizedDescription))
            } catch CocoaError.userCancelled {
                outcome.cancelled = true
                break
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                outcome.offline += 1
            } catch {
                outcome.failed.append(Problem(name: name, reason: error.localizedDescription))
            }
            progress(index + 1)
        }
        return outcome
    }
}

struct SmartPreviewOutcome: Sendable {
    var made = 0
    var offline = 0
    var notDownloaded = 0
    var cancelled = false
    var failed: [Problem] = []

    var summary: String {
        var parts = ["Built \(made == 1 ? "1 smart preview" : "\(made.formatted()) smart previews")"]
        if offline > 0 { parts.append("\(offline.formatted()) offline, skipped") }
        if notDownloaded > 0 { parts.append("\(notDownloaded.formatted()) not downloaded from the cloud, skipped") }
        if !failed.isEmpty { parts.append("\(failed.count.formatted()) couldn't be built") }
        return parts.joined(separator: "; ") + (cancelled ? " before Cancel." : ".")
    }
}
