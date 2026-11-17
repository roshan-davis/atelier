import AtelierActions
import AtelierCore
import Foundation

/// The Keep on This Mac dialog's subject, fixed when it opens (AT-079c).
struct KeepRequest: Identifiable {
    let id = UUID()
    let place: KeepPlace
    /// "Trip to Kerala", "megham".
    let name: String
    let plan: KeepPlan

    /// "Keep 412 photos from “Trip” on this Mac?"
    var title: String {
        let count = plan.toRead.count + plan.toPin.count
        return "Keep \(count == 1 ? "1 photo" : "\(count.formatted()) photos") from \u{201C}\(name)\u{201D} on this Mac?"
    }

    /// "11.6 GB will be read from megham. They'll open at full quality when megham is offline."
    var message: String {
        var lines: [String] = []
        if plan.readBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: plan.readBytes, countStyle: .file)
            lines.append("\(size) will be read from \(plan.sources.formatted(.list(type: .and))), in the background.")
        } else {
            lines.append("They're already on this Mac; nothing needs to be read.")
        }
        if plan.alreadyKept > 0 { lines.append("\(plan.alreadyKept.formatted()) already kept.") }
        if plan.offline > 0 { lines.append("\(plan.offline.formatted()) on a share that's offline will be skipped.") }
        lines.append("Kept photos open at full quality while their share is offline, and don't count toward the cache size.")
        return lines.joined(separator: " ")
    }

    /// The refusal when the read wouldn't leave 10% of the disk free.
    var shortMessage: String {
        let size = ByteCountFormatter.string(fromByteCount: plan.readBytes, countStyle: .file)
        let short = ByteCountFormatter.string(fromByteCount: plan.shortBy ?? 0, countStyle: .file)
        return "Keeping these photos needs \(size), and Atelier always leaves at least 10% of this Mac's disk free. Free up \(short) and try again, or keep a smaller folder or collection."
    }
}

extension LibraryModel {
    static func keepPlace(_ parameters: KeepParameters) -> KeepPlace {
        switch parameters.place {
        case .folder: return .folder(parameters.id)
        case .importEntry: return .importGroup(parameters.id)
        case .collection: return .collection(parameters.id)
        case .location: return .location(parameters.id)
        }
    }

    /// The place's name as the sidebar shows it.
    func keepName(_ place: KeepPlace) -> String {
        switch place {
        case .folder(let id):
            let folder = sidebar.folders.first { $0.id == id }
            return folder.map { ($0.relativePath as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
                ?? folder?.displayName ?? "this folder"
        case .importGroup(let id): return sidebar.imports.first { $0.id == id }?.name ?? "this import"
        case .collection(let id): return sidebar.collections.first { $0.id == id }?.name ?? "this collection"
        case .location(let id): return sidebar.locations.first { $0.id == id }?.location.name ?? "this location"
        }
    }

    /// Whether a sidebar folder or location holds photos on a network share (from the sidebar's
    /// own data, no file or network access), so its menu offers Keep on This Mac.
    func canKeep(_ place: KeepPlace) -> Bool {
        guard originals != nil else { return false }
        let shares = Set(sidebar.volumes.filter { $0.kind == .nas }.compactMap(\.id))
        switch place {
        case .folder(let id):
            return sidebar.folders.first { $0.id == id }.map { shares.contains($0.volumeId) } ?? false
        case .location(let id):
            return sidebar.locations.first { $0.id == id }?.location.volumeId.map(shares.contains) ?? false
        case .importGroup, .collection:
            return !shares.isEmpty
        }
    }

    /// Keep on This Mac…: works out what would be read (off the main thread; no photo is read) and
    /// shows the size first, or refuses when it wouldn't leave 10% of the disk free.
    func beginKeep(_ place: KeepPlace) {
        guard let originals else { return }
        let catalog = self.catalog
        let name = keepName(place)
        Task {
            let planned = await Task.detached(priority: .userInitiated) { () -> Result<KeepPlan, Error> in
                Result {
                    let found = try catalog.shareOriginals(in: place)
                    let disk = originals.diskSpace()
                    return try originals.keepPlan(for: found.originals, photoCount: found.photoCount,
                                                  free: disk.free, capacity: disk.capacity)
                }
            }.value
            switch planned {
            case .failure(let error):
                status = "Couldn't work out what to keep: \(error.localizedDescription)"
            case .success(let plan) where plan.isEmpty:
                status = Self.nothingToKeep(plan, name: name)
            case .success(let plan):
                keepRequest = KeepRequest(place: place, name: name, plan: plan)
            }
        }
    }

    private static func nothingToKeep(_ plan: KeepPlan, name: String) -> String {
        if plan.shareCount == 0 {
            return "None of the photos in \u{201C}\(name)\u{201D} are on a network share. Photos on this Mac and in cloud drive folders don't need keeping."
        }
        if plan.offline > 0 && plan.alreadyKept == 0 {
            return "The photos in \u{201C}\(name)\u{201D} are on a share that's offline. Connect it, then choose Keep on This Mac again."
        }
        return "All \(plan.alreadyKept.formatted()) photos in \u{201C}\(name)\u{201D} on network shares are already kept on this Mac."
    }

    /// Runs a confirmed Keep on This Mac: the copies already here are kept at once, the rest read
    /// one at a time behind the photo being opened (each read pauses while it reads), with
    /// progress and Cancel in the status bar. Cancel keeps what was read. Requests run in turn.
    func keep(_ request: KeepRequest) {
        keepRequest = nil
        guard let originals, request.plan.fits else { return }
        let plan = request.plan
        let name = request.name
        let paused = foregroundReading
        let previous = keepTask
        let total = plan.readBytes
        let count = plan.toRead.count
        keepTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let phase = { (done: Int, bytes: Int64) in
                "Keeping \u{201C}\(name)\u{201D} on this Mac · \(min(done + 1, count)) of \(count) · "
                    + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " of \(totalText)"
            }
            if count > 0 { keepProgress = ImportStatus(phase: phase(0, 0), fraction: 0) }
            let relay = ProgressRelay { [weak self] packed in
                guard let self, self.keepProgress != nil else { return }
                let done = Int(packed >> 48)
                let bytes = packed & 0xFFFF_FFFF_FFFF
                self.keepProgress = ImportStatus(phase: phase(done, bytes), fraction: total > 0 ? min(1, Double(bytes) / Double(total)) : nil)
            }
            let run = Task.detached(priority: .utility) { () -> KeepOutcome in
                Self.runKeep(plan, originals: originals, paused: paused) { done, bytes in
                    relay.send(Int64(done) << 48 | bytes)
                }
            }
            let outcome = await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
            keepProgress = nil
            status = outcome.summary(name: name)
        }
    }

    /// The status bar's Cancel: stops reading; what was read stays kept.
    func cancelKeep() {
        keepTask?.cancel()
        keepTask = nil
        keepProgress = nil
    }

    nonisolated private static func runKeep(_ plan: KeepPlan, originals: OriginalCache, paused: LockedValue<Bool>,
                                            progress: @escaping @Sendable (Int, Int64) -> Void) -> KeepOutcome {
        var outcome = KeepOutcome()
        do {
            try originals.setKept(plan.toPin, true)
            outcome.kept += plan.toPin.count
        } catch {
            outcome.failed.append(error.localizedDescription)
        }
        var bytesDone: Int64 = 0
        for (index, original) in plan.toRead.enumerated() {
            if Task.isCancelled { outcome.cancelled = true; break }
            guard let source = original.fileURL else { continue }
            // The disk can fill while this runs (another app, an import): check before each file.
            let disk = originals.diskSpace()
            if KeepPlan.shortfall(reading: original.fileSize, free: disk.free, capacity: disk.capacity) != nil {
                outcome.outOfSpace = true
                break
            }
            do {
                // Opened in Develop (or read ahead) since the plan: keep that copy.
                if (try originals.copy(for: original.assetId, contentHash: original.contentHash,
                                       source: OriginalCache.SourceInfo(source))) != nil {
                    try originals.setKept([original.assetId], true)
                    outcome.kept += 1
                } else {
                    let before = bytesDone
                    let result = try originals.store(original.assetId, from: source, contentHash: original.contentHash,
                                                     pinned: true, progress: { progress(index, before + $0) },
                                                     shouldPause: { paused.value })
                    switch result {
                    case .stored: outcome.kept += 1
                    case .changed: outcome.changed.append(original.filename)
                    }
                }
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch {
                outcome.failed.append("\(original.filename): \(error.localizedDescription)")
                // The share went away: the rest would fail the same way.
                if !FileManager.default.fileExists(atPath: source.deletingLastPathComponent().path) {
                    outcome.offline = original.volumeName
                    break
                }
            }
            bytesDone += original.fileSize
            outcome.bytes = bytesDone
            progress(index + 1, bytesDone)
        }
        return outcome
    }

    /// Free Up Space: the copies kept for the place's photos go, except the one open in Develop
    /// (it stops being kept and goes with the rest of the cache later). The originals aren't touched.
    func freeUpSpace(_ place: KeepPlace) {
        guard let originals else { return }
        cancelKeep()
        let catalog = self.catalog
        let name = keepName(place)
        let open = mode == .develop ? develop.assetID.flatMap { try? catalog.originalID(for: $0) } : nil
        Task {
            let freed = await Task.detached(priority: .userInitiated) { () -> Result<(count: Int, bytes: Int64), Error> in
                Result {
                    let ids = try catalog.shareOriginals(in: place).originals.map(\.assetId)
                    return try originals.freeUp(ids, sparing: open)
                }
            }.value
            switch freed {
            case .failure(let error):
                status = "Couldn't free up space: \(error.localizedDescription)"
            case .success(let result) where result.count == 0:
                status = "No photos from \u{201C}\(name)\u{201D} are kept on this Mac."
            case .success(let result):
                DeleteFeedback.play(.remove)
                let size = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)
                status = "Freed \(size) from \u{201C}\(name)\u{201D}. The originals stay on the share and are read again when you open them."
            }
        }
    }
}

/// What a Keep on This Mac run came to, for the status line.
struct KeepOutcome: Sendable {
    var kept = 0
    var bytes: Int64 = 0
    var changed: [String] = []
    var failed: [String] = []
    var cancelled = false
    var outOfSpace = false
    /// The share that went offline mid-run.
    var offline: String?

    func summary(name: String) -> String {
        var line = "Kept \(kept == 1 ? "1 photo" : "\(kept.formatted()) photos") from \u{201C}\(name)\u{201D} on this Mac"
        if bytes > 0 { line += " (" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " read)" }
        line += "."
        if cancelled { line += " Stopped; the rest weren't read." }
        if outOfSpace { line += " Stopped to leave 10% of the disk free." }
        if let offline { line += " Stopped: \(offline) went offline." }
        if !changed.isEmpty {
            line += " \(changed.count == 1 ? changed[0] + " has" : "\(changed.count) photos have") changed on the share since import and weren't kept."
        } else if !failed.isEmpty, offline == nil {
            line += " \(failed.count == 1 ? "1 couldn't" : "\(failed.count) couldn't") be read: \(failed[0])"
        }
        return line
    }
}
