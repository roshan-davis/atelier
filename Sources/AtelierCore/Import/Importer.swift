import Foundation
import GRDB

public enum ImportMode: Sendable, Hashable {
    /// Files stay where they are, on a local drive or the NAS.
    case reference
    /// Files are copied to `destinationRoot/YYYY/YYYY-MM-DD Event/` and hash-verified.
    case copy(destinationRoot: URL, eventName: String)
}

/// Which import entry the photos land in.
public enum ImportTarget: Sendable, Hashable {
    /// A new entry. A blank name falls back to the first source folder's name.
    case newGroup(name: String)
    /// Add to an entry that already exists.
    case existingGroup(Int64)
}

public struct ImportOptions: Sendable {
    public var mode: ImportMode
    public var target: ImportTarget
    /// Applied to every imported photo (metadata preset, keywords part).
    public var keywords: [String]
    public var buildPreviews: Bool

    public init(mode: ImportMode = .reference, target: ImportTarget = .newGroup(name: ""),
                keywords: [String] = [], buildPreviews: Bool = true) {
        self.mode = mode
        self.target = target
        self.keywords = keywords
        self.buildPreviews = buildPreviews
    }
}

public struct ImportFailure: Sendable, Hashable {
    public var url: URL
    public var reason: String
}

public struct ImportProgress: Sendable {
    public var total = 0
    public var processed = 0
    public var imported = 0
    /// Already in the catalog (same folder and filename).
    public var skipped = 0
    public var previewsBuilt = 0
    public var failures: [ImportFailure] = []
    public var importedAssetIDs: [Int64] = []
    /// The import entry the photos were added to.
    public var importGroupId: Int64?
}

enum ImportOutcome {
    case imported(Int64, URL)
    /// Already in the catalog; it still joins the import entry.
    case existing(Int64)
}

/// Imports files into the catalog. Originals are only ever read, never modified.
public final class Importer: Sendable {
    let catalog: Catalog
    let previews: PreviewCache?
    let scheduler: PreviewScheduler?

    /// With a scheduler, each photo's thumbnail is queued as soon as it is cataloged and the
    /// 2560 px previews follow on the slow lane, so the grid fills in during the import.
    /// Without one, `previews` are built synchronously at the end.
    public init(catalog: Catalog, previews: PreviewCache?, scheduler: PreviewScheduler? = nil) {
        self.catalog = catalog
        self.previews = previews ?? scheduler?.cache
        self.scheduler = scheduler
    }

    /// Expands folders recursively into supported image files, sorted by path.
    public static func collectFiles(from sources: [URL]) -> [URL] {
        var files: [URL] = []
        for source in sources {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if MetadataReader.isSupported(source) { files.append(source) }
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isFile && MetadataReader.isSupported(url) { files.append(url) }
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public func run(sources: [URL], options: ImportOptions,
                    progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async -> ImportProgress {
        let files = Self.collectFiles(from: sources)
        var state = ImportProgress()
        state.total = files.count
        do {
            state.importGroupId = try resolveGroup(options.target, sources: sources)
        } catch {
            state.failures.append(ImportFailure(url: sources.first ?? URL(fileURLWithPath: "/"),
                                                reason: error.localizedDescription))
        }
        progress(state)

        for file in files {
            if Task.isCancelled { break }
            do {
                let assetID: Int64
                switch try importFile(file, options: options) {
                case .imported(let id, let url):
                    state.imported += 1
                    state.importedAssetIDs.append(id)
                    assetID = id
                    if options.buildPreviews { scheduler?.request(.thumbnail, for: id, source: url) }
                case .existing(let id):
                    state.skipped += 1
                    assetID = id
                }
                if let groupID = state.importGroupId {
                    try catalog.addAssets([assetID], toImportGroup: groupID)
                }
            } catch {
                state.failures.append(ImportFailure(url: file, reason: error.localizedDescription))
            }
            state.processed += 1
            progress(state)
        }

        if options.buildPreviews, let scheduler {
            for id in state.importedAssetIDs {
                if let url = try? catalog.fileURL(for: id) {
                    scheduler.request(.preview, for: id, source: url)
                }
            }
        } else if options.buildPreviews, let previews {
            let base = state
            state.previewsBuilt = await buildPreviews(for: state.importedAssetIDs, cache: previews) { built in
                var snapshot = base
                snapshot.previewsBuilt = built
                progress(snapshot)
            }
            progress(state)
        }
        return state
    }

    func resolveGroup(_ target: ImportTarget, sources: [URL]) throws -> Int64 {
        switch target {
        case .existingGroup(let id):
            return id
        case .newGroup(let name):
            let fallback = sources.first.map { url -> String in
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return isDirectory.boolValue ? url.lastPathComponent : url.deletingLastPathComponent().lastPathComponent
            } ?? ""
            return try catalog.createImportGroup(named: name.nilIfBlank ?? fallback).id!
        }
    }

    func importFile(_ source: URL, options: ImportOptions) throws -> ImportOutcome {
        // Re-importing a referenced folder should not re-hash files that are already cataloged.
        if options.mode == .reference, let existing = try existingAssetID(for: source) {
            return .existing(existing)
        }

        let metadata = MetadataReader.read(source)
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let hash = try FileHasher.sha256(of: source)
        var fileURL = source

        if case let .copy(root, eventName) = options.mode {
            let date = metadata.captureTime ?? sourceValues.contentModificationDate ?? Date()
            let directory = Self.destinationDirectory(root: root, date: date, eventName: eventName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = try Self.copyVerified(source, hash: hash, into: directory)
        }

        let volume = try VolumeIdentity.volume(containing: fileURL)
        let relativeFolder = VolumeIdentity.relativePath(of: fileURL.deletingLastPathComponent(),
                                                         inVolumeAt: volume.rootURL)
        let filename = fileURL.lastPathComponent
        let importedURL = fileURL

        return try catalog.writer.write { db -> ImportOutcome in
            var volumeRecord = try Volume.filter(Column("identityKey") == volume.identityKey).fetchOne(db)
                ?? Volume(id: nil, identityKey: volume.identityKey, name: volume.name, kind: volume.kind,
                          mountPath: nil, lastSeen: nil, isOnline: true)
            volumeRecord.name = volume.name
            volumeRecord.kind = volume.kind
            volumeRecord.mountPath = volume.rootURL.path
            volumeRecord.lastSeen = Date()
            volumeRecord.isOnline = true
            try volumeRecord.save(db)

            var folder = try Folder
                .filter(Column("volumeId") == volumeRecord.id! && Column("relativePath") == relativeFolder)
                .fetchOne(db)
                ?? Folder(id: nil, volumeId: volumeRecord.id!, relativePath: relativeFolder)
            if folder.id == nil { try folder.insert(db) }

            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM asset WHERE folderId = ? AND filename = ?",
                                                 arguments: [folder.id!, filename]) {
                return .existing(existing)
            }

            var asset = Asset(
                id: nil, folderId: folder.id!, filename: filename,
                fileSize: Int64(sourceValues.fileSize ?? 0),
                modifiedAt: sourceValues.contentModificationDate, contentHash: hash,
                perceptualHash: nil, captureTime: metadata.captureTime,
                cameraMake: metadata.cameraMake, cameraModel: metadata.cameraModel, lens: metadata.lens,
                width: metadata.width, height: metadata.height, orientation: metadata.orientation,
                uti: metadata.uti, importedAt: Date())
            try asset.insert(db)
            let assetID = asset.id!

            try AssetMetadata(
                assetId: assetID,
                rating: metadata.xmp.rating ?? 0,
                flag: metadata.xmp.flag ?? .none,
                colorLabel: metadata.xmp.colorLabel,
                title: metadata.xmp.title,
                caption: metadata.xmp.caption,
                latitude: metadata.latitude,
                longitude: metadata.longitude
            ).insert(db)

            try Catalog.addKeywords(db, names: metadata.xmp.keywords + options.keywords, to: [assetID])
            return .imported(assetID, importedURL)
        }
    }

    func existingAssetID(for url: URL) throws -> Int64? {
        let volume = try VolumeIdentity.volume(containing: url)
        let relativeFolder = VolumeIdentity.relativePath(of: url.deletingLastPathComponent(),
                                                         inVolumeAt: volume.rootURL)
        return try catalog.writer.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT asset.id FROM asset
                JOIN folder ON folder.id = asset.folderId
                JOIN volume ON volume.id = folder.volumeId
                WHERE volume.identityKey = ? AND folder.relativePath = ? AND asset.filename = ?
                """, arguments: [volume.identityKey, relativeFolder, url.lastPathComponent])
        }
    }

    /// Builds previews with a few parallel workers. Returns how many succeeded.
    public func buildPreviews(for assetIDs: [Int64], cache: PreviewCache,
                              progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> Int {
        let catalog = self.catalog
        let jobs: [(Int64, URL)] = assetIDs.compactMap { id in
            (try? catalog.fileURL(for: id)).map { (id, $0) }
        }
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        return await withTaskGroup(of: Bool.self) { group in
            var built = 0
            var pending = jobs.makeIterator()
            for _ in 0..<workers {
                guard case let (id, url)? = pending.next() else { break }
                group.addTask { (try? cache.generate(for: id, from: url)) != nil }
            }
            for await ok in group {
                if ok {
                    built += 1
                    progress(built)
                }
                if case let (id, url)? = pending.next() {
                    group.addTask { (try? cache.generate(for: id, from: url)) != nil }
                }
            }
            return built
        }
    }

    // MARK: Copy mode

    static func destinationDirectory(root: URL, date: Date, eventName: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: date)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let event = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let folderName = event.isEmpty ? day : "\(day) \(event)"
        return root.appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Copies `source` into `directory` and verifies the copy by hash. If an identical file is
    /// already there, it is reused; a different file with the same name gets a numeric suffix.
    static func copyVerified(_ source: URL, hash: String, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            if (try? FileHasher.sha256(of: candidate)) == hash { return candidate }
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        try fm.copyItem(at: source, to: candidate)
        guard try FileHasher.sha256(of: candidate) == hash else {
            try? fm.removeItem(at: candidate)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: candidate.path,
                NSLocalizedDescriptionKey: "Copy of \(source.lastPathComponent) failed hash verification.",
            ])
        }
        // Bring an existing XMP sidecar along so ratings and keywords from other apps survive.
        let sidecar = XMPSidecar.sidecarURL(for: source)
        let sidecarDestination = XMPSidecar.sidecarURL(for: candidate)
        if fm.fileExists(atPath: sidecar.path) && !fm.fileExists(atPath: sidecarDestination.path) {
            try? fm.copyItem(at: sidecar, to: sidecarDestination)
        }
        return candidate
    }
}
