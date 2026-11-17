import AtelierCore
import Foundation

/// What making an original ready on this Mac came to (AT-079b, AT-079c).
enum OriginalPrep: Sendable {
    /// The file to read: the copy on this Mac, the downloaded cloud file, or a local original.
    case ready(URL)
    case offline
    case cancelled
    case failed(String)
}

/// Remote originals for Develop: a photo on a network share is read once into the cache of
/// originals (`OriginalCache`) and opened from there; a photo still only in a cloud drive folder is
/// downloaded by the provider's app. Either way the preview stays on screen, the status bar shows
/// the transfer with Cancel, and nothing runs on the main thread. One foreground transfer at a time:
/// opening another photo cancels the one before, so the photo you're on never waits behind one you
/// passed. The neighbours' originals on a share are read behind it, one at a time, pausing while the
/// open photo reads (PRD "Never feel the network on the photo being worked on").
extension LibraryModel {
    static let originalCacheLimitKey = "originalCacheLimit"

    /// The cache of originals, or nil when its folder can't be made (Develop then reads originals
    /// where they are, as before).
    static func makeOriginalCache() -> OriginalCache? {
        let stored = UserDefaults.standard.object(forKey: originalCacheLimitKey) as? Int64
        return try? OriginalCache(limit: stored ?? OriginalCache.defaultLimit)
    }

    /// Whether `prepareOriginal` has work to do before Develop decodes. In-memory only: no file or
    /// network access on the main thread, except a cloud file's flags on this Mac's disk.
    func originalNeedsPreparing(_ assetID: Int64, url: URL?) -> Bool {
        // A copy in the cache was checked this session (`readableURL` hands out only those).
        if let url, let originals,
           url.deletingLastPathComponent().standardizedFileURL.path == originals.root.standardizedFileURL.path { return false }
        guard let kind = volumeKind(of: assetID) else { return false }
        switch kind {
        case .local: return false
        case .nas: return originals != nil
        case .cloud: return url.map(CloudFiles.needsDownload) ?? false
        }
    }

    func prepareOriginal(_ assetID: Int64) async -> OriginalPrep {
        guard let detail = try? catalog.detail(for: assetID) else { return .failed("This photo is no longer in the catalog.") }
        switch detail.volume.kind {
        case .local:
            return detail.fileURL.map(OriginalPrep.ready) ?? .offline
        case .cloud:
            guard let url = detail.fileURL else { return .offline }
            guard CloudFiles.needsDownload(url) else { return .ready(url) }
            return await downloadCloudOriginal(assetID, at: url)
        case .nas:
            guard let originals else { return detail.fileURL.map(OriginalPrep.ready) ?? .offline }
            return await readIntoCache(detail, originals: originals)
        }
    }

    /// Stops the transfer for the open photo (the status bar's Cancel).
    func cancelOriginalTransfer() {
        originalTransfer?.cancel()
        cloudDownload?.download.cancel()
    }

    // MARK: Network share → cache

    private func readIntoCache(_ detail: AssetDetail, originals: OriginalCache) async -> OriginalPrep {
        // Filed under the master's id, so a virtual copy never stores the same file twice.
        guard let assetID = detail.asset.virtualCopyOf ?? detail.asset.id else { return .offline }
        originals.inUse = assetID
        let source = detail.fileURL
        let hash = detail.asset.contentHash
        let place = locationName(for: detail.volume)
        // One metadata read of the original (off the main thread: a sleeping NAS can take a while).
        let checked = await Task.detached(priority: .userInitiated) { () -> Result<OriginalCache.Copy?, Error> in
            let info = source.flatMap(OriginalCache.SourceInfo.init)
            return Result { try originals.copy(for: assetID, contentHash: hash, source: info) }
        }.value
        if case .success(let copy?) = checked {
            if !copy.checked {
                let day = copy.storedAt.formatted(.dateTime.month(.abbreviated).day())
                status = "Using the copy on this Mac from \(day); \(place) is offline, so changes there can't be checked."
            }
            return .ready(copy.url)
        }
        guard let source else { return .offline }

        originalTransfer?.cancel()
        foregroundReading.value = true
        let bytes = detail.asset.fileSize
        let size = bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
        let phase = "Reading \(source.lastPathComponent)\(size) from \(place)…"
        downloadProgress = ImportStatus(phase: phase, fraction: 0)
        let progress = ProgressRelay { [weak self] copied in
            guard let self, bytes > 0 else { return }
            self.downloadProgress = ImportStatus(phase: phase, fraction: min(1, Double(copied) / Double(bytes)))
        }
        let task = Task.detached(priority: .userInitiated) { () throws -> OriginalCache.StoreResult in
            try originals.store(assetID, from: source, contentHash: hash, progress: { progress.send($0) })
        }
        originalTransfer = task
        let result = await task.result
        if originalTransfer == task {
            originalTransfer = nil
            downloadProgress = nil
            foregroundReading.value = false
        }
        switch result {
        case .success(.stored(let copy)):
            return .ready(copy)
        case .success(.changed):
            return .failed("\(source.lastPathComponent) changed on \(place) since it was imported, so Atelier didn't use it. Import it again to edit the new file.")
        case .failure(is CancellationError):
            return .cancelled
        case .failure(let error):
            return .failed("Couldn't read \(source.lastPathComponent) from \(place): \(error.localizedDescription)")
        }
    }

    /// Reads the originals of the photos around the open one into the cache, one at a time, behind
    /// the open photo's own read. Only photos on a share: a cloud file is never downloaded unasked.
    func prefetchOriginals(_ ids: [Int64]) {
        prefetchTask?.cancel()
        guard let originals, !ids.isEmpty else { return }
        let catalog = self.catalog
        let shareVolumes = Set(sidebar.volumes.filter { $0.kind == .nas && $0.isOnline }.compactMap(\.id))
        guard !shareVolumes.isEmpty else { return }
        let paused = foregroundReading
        prefetchTask = Task.detached(priority: .utility) {
            for id in ids {
                guard !Task.isCancelled else { return }
                guard let detail = try? catalog.detail(for: id), let volumeId = detail.volume.id,
                      shareVolumes.contains(volumeId), let source = detail.fileURL else { continue }
                let id = detail.asset.virtualCopyOf ?? id
                let hash = detail.asset.contentHash
                if (try? originals.copy(for: id, contentHash: hash, source: OriginalCache.SourceInfo(source))) != nil { continue }
                _ = try? originals.store(id, from: source, contentHash: hash, readAhead: true, shouldPause: { paused.value })
            }
        }
    }

    // MARK: Cloud drive folder → provider download (AT-079b)

    private func downloadCloudOriginal(_ assetID: Int64, at url: URL) async -> OriginalPrep {
        cloudDownload?.download.cancel()
        let download = CloudDownload()
        cloudDownload = (assetID, download)
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let size = bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
        let provider = providerName(for: url)
        downloadProgress = ImportStatus(phase: "Downloading \(url.lastPathComponent)\(size) from \(provider)…", fraction: nil)
        let result: OriginalPrep
        do {
            try await download.run(url)
            result = .ready(url)
        } catch is CancellationError {
            result = .cancelled
        } catch {
            result = .failed("Couldn't download \(url.lastPathComponent) from \(provider): \(error.localizedDescription)")
        }
        // A newer download replaced this one: leave its progress alone.
        if cloudDownload?.download === download {
            cloudDownload = nil
            downloadProgress = nil
        }
        if case .ready = result { markDownloaded(assetID) }
        return result
    }

    /// The grid's cloud badge goes as soon as the file is here (the folder isn't watched).
    private func markDownloaded(_ assetID: Int64) {
        if let index = rows.firstIndex(where: { $0.id == assetID }), rows[index].notDownloaded {
            rows[index].notDownloaded = false
        }
    }

    // MARK: Names

    private func volumeKind(of assetID: Int64) -> VolumeKind? {
        guard let folderId = rows.first(where: { $0.id == assetID })?.folderId ?? detail.flatMap({ $0.asset.id == assetID ? $0.folder.id : nil }),
              let volumeId = sidebar.folders.first(where: { $0.id == folderId })?.volumeId else {
            return (try? catalog.detail(for: assetID))?.volume.kind
        }
        return sidebar.volumes.first { $0.id == volumeId }?.kind
    }

    /// "megham": the location the volume's root belongs to, else the volume's name.
    private func locationName(for volume: Volume) -> String {
        sidebar.locations.first { $0.location.volumeId == volume.id && $0.location.rootPath.isEmpty }?.location.name
            ?? volume.name
    }

    /// "Dropbox", "iCloud Drive": the location holding the file, else its provider folder.
    private func providerName(for url: URL) -> String {
        let path = url.path
        if let info = sidebar.locations.first(where: { info in
            guard info.location.kind == .cloudFolder, let root = info.rootURL?.path else { return false }
            return path.hasPrefix(root + "/")
        }) {
            return info.location.name
        }
        return CloudFolders.provider(containing: url, in: CloudFolders.providers())?.name ?? "the cloud"
    }
}

/// Hands a background copy's byte count to the main actor, at most ten times a second, so a
/// 2 GB TIFF doesn't send 250 updates.
final class ProgressRelay: @unchecked Sendable {
    private let deliver: @MainActor (Int64) -> Void
    private let lock = NSLock()
    private var last = Date.distantPast

    init(_ deliver: @escaping @MainActor (Int64) -> Void) {
        self.deliver = deliver
    }

    func send(_ copied: Int64) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            guard now.timeIntervalSince(last) >= 0.1 else { return false }
            last = now
            return true
        }
        guard due else { return }
        Task { @MainActor in self.deliver(copied) }
    }
}
