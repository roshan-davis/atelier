import CryptoKit
import Darwin
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
    /// Develop preset applied to newly imported photos.
    public var developPreset: DevelopPreset?

    public init(mode: ImportMode = .reference, target: ImportTarget = .newGroup(name: ""),
                keywords: [String] = [], buildPreviews: Bool = true, developPreset: DevelopPreset? = nil) {
        self.mode = mode
        self.target = target
        self.keywords = keywords
        self.buildPreviews = buildPreviews
        self.developPreset = developPreset
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
    /// Each source file's photo, new or already in the catalog.
    public var assetIDsBySource: [URL: Int64] = [:]
    /// The size of every file to import, and of those handled so far.
    public var totalBytes: Int64 = 0
    public var bytesDone: Int64 = 0
    /// The file most recently started.
    public var currentFile: URL?
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

    /// With a scheduler, thumbnails are queued once every file is cataloged and the 2560 px
    /// previews follow on the slow lane.
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

    /// Files are handled a few at a time (reading, hashing and copying overlap), and nothing is
    /// rendered until every file is cataloged: thumbnails and previews are queued at the end, so
    /// they don't compete with the copy for the disk.
    public func run(sources: [URL], options: ImportOptions,
                    progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async -> ImportProgress {
        let files = Self.collectFiles(from: sources)
        let sizes = files.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var state = ImportProgress()
        state.total = files.count
        state.totalBytes = sizes.reduce(0, +)
        state.currentFile = files.first
        do {
            state.importGroupId = try resolveGroup(options.target, sources: sources)
        } catch {
            state.failures.append(ImportFailure(url: sources.first ?? URL(fileURLWithPath: "/"),
                                                reason: error.localizedDescription))
        }
        progress(state)

        /// Imported photos by file index, so the result keeps the files' order.
        var imported: [(index: Int, id: Int64, url: URL)] = []
        await withTaskGroup(of: (Int, Result<ImportOutcome, Error>).self) { group in
            var next = 0
            for _ in 0..<min(Self.workers(for: options.mode), files.count) {
                let index = next
                next += 1
                group.addTask { (index, Result { try self.importFile(files[index], options: options) }) }
            }
            for await (index, outcome) in group {
                let file = files[index]
                do {
                    let assetID: Int64
                    switch try outcome.get() {
                    case .imported(let id, let url):
                        state.imported += 1
                        imported.append((index, id, url))
                        assetID = id
                        if let preset = options.developPreset {
                            try? catalog.saveDevelopSettings(preset.applied(to: .neutral), for: id,
                                                             step: "Import Preset: \(preset.name)")
                        }
                    case .existing(let id):
                        state.skipped += 1
                        assetID = id
                    }
                    state.assetIDsBySource[file] = assetID
                    if let groupID = state.importGroupId {
                        try catalog.addAssets([assetID], toImportGroup: groupID)
                    }
                } catch is CancellationError {
                    // The file was left out; its partial copy is already gone.
                } catch {
                    state.failures.append(ImportFailure(url: file, reason: error.localizedDescription))
                }
                state.processed += 1
                state.bytesDone += sizes[index]
                if !Task.isCancelled, next < files.count {
                    let index = next
                    next += 1
                    state.currentFile = files[index]
                    group.addTask { (index, Result { try self.importFile(files[index], options: options) }) }
                }
                progress(state)
            }
        }
        imported.sort { $0.index < $1.index }
        state.importedAssetIDs = imported.map(\.id)

        if options.buildPreviews, let scheduler {
            let settings = options.developPreset.map { $0.applied(to: .neutral) }
            for photo in imported {
                scheduler.request(.thumbnail, for: photo.id, source: photo.url, settings: settings)
            }
            for photo in imported {
                scheduler.request(.preview, for: photo.id, source: photo.url, settings: settings)
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

    /// Files handled at once. Copies are bound by the card or drive, hashing a referenced file
    /// by the CPU too.
    static func workers(for mode: ImportMode) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch mode {
        case .copy: return 4
        case .reference: return min(8, max(2, cores / 2))
        }
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

        try Task.checkCancellation()
        let metadata = MetadataReader.read(source)
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let hash: String
        var fileURL = source

        if case let .copy(root, eventName) = options.mode {
            let date = metadata.captureTime ?? sourceValues.contentModificationDate ?? Date()
            let directory = Self.destinationDirectory(root: root, date: date, eventName: eventName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = try Self.copyVerified(source, into: directory)
            fileURL = copy.url
            hash = copy.hash
        } else {
            hash = try FileHasher.sha256(of: source)
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

            if let existing = try Int64.fetchOne(db, sql: """
                SELECT id FROM asset WHERE folderId = ? AND filename = ? AND virtualCopyOf IS NULL
                """,
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
                uti: metadata.uti, importedAt: Date(),
                stem: FilePairs.stem(of: filename), isRaw: FilePairs.isRaw(filename))
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
                  AND asset.virtualCopyOf IS NULL
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
                group.addTask { Self.generate(id, url, cache: cache, catalog: catalog) }
            }
            for await ok in group {
                if ok {
                    built += 1
                    progress(built)
                }
                if case let (id, url)? = pending.next() {
                    group.addTask { Self.generate(id, url, cache: cache, catalog: catalog) }
                }
            }
            return built
        }
    }

    /// Builds a photo's previews, developed when it already has settings.
    private static func generate(_ id: Int64, _ url: URL, cache: PreviewCache, catalog: Catalog) -> Bool {
        if let settings = try? catalog.developSettings(for: id), !settings.isNeutral {
            return (try? cache.generateDeveloped(for: id, from: url, settings: settings)) != nil
        }
        return (try? cache.generate(for: id, from: url)) != nil
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

    /// Copies `source` into `directory`, verifies the copy by hash and returns it with the
    /// source's hash. If an identical file is already there, it is reused; a different file with
    /// the same name gets a numeric suffix. Safe to run for several files at once.
    ///
    /// Copying from another drive or a card reads the source once, hashing it on the way. On the
    /// same APFS volume the copy is a clone, which takes no time or space.
    static func copyVerified(_ source: URL, into directory: URL) throws -> (url: URL, hash: String) {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        /// Only needed when the name is taken, to tell an earlier copy from a different photo.
        var sourceHash: String?
        // Creating the file exclusively claims the name, so two copies never pick the same one.
        var reserved = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        while reserved < 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let hash = try sourceHash ?? FileHasher.sha256(of: source)
            sourceHash = hash
            if (try? FileHasher.sha256(of: candidate)) == hash { return (candidate, hash) }
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
            reserved = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }

        let hash: String
        do {
            if Self.sameVolume(source, directory) {
                close(reserved)
                // A clone (or a plain copy where cloning isn't supported) replaces the placeholder.
                let temporary = directory.appendingPathComponent(".\(UUID().uuidString).atelier-copy")
                guard copyfile(source.path, temporary.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) == 0 else {
                    let code = errno
                    try? fm.removeItem(at: temporary)
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                guard rename(temporary.path, candidate.path) == 0 else {
                    let code = errno
                    try? fm.removeItem(at: temporary)
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                hash = try sourceHash ?? FileHasher.sha256(of: source)
            } else {
                hash = try copyHashing(source, to: reserved)
                if let sourceHash, sourceHash != hash {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSFilePathErrorKey: source.path,
                        NSLocalizedDescriptionKey: "\(source.lastPathComponent) changed while it was being copied.",
                    ])
                }
            }
            try Task.checkCancellation()
            guard try FileHasher.sha256(of: candidate) == hash else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: candidate.path,
                    NSLocalizedDescriptionKey: "Copy of \(source.lastPathComponent) failed hash verification.",
                ])
            }
        } catch {
            try? fm.removeItem(at: candidate)
            throw error
        }
        // Bring an existing XMP sidecar along so ratings and keywords from other apps survive.
        let sidecar = XMPSidecar.sidecarURL(for: source)
        let sidecarDestination = XMPSidecar.sidecarURL(for: candidate)
        if fm.fileExists(atPath: sidecar.path) && !fm.fileExists(atPath: sidecarDestination.path) {
            try? fm.copyItem(at: sidecar, to: sidecarDestination)
        }
        return (candidate, hash)
    }

    /// Copies `source` into the open file `destination` (and closes it), hashing what it reads,
    /// then gives the copy the source's dates, permissions and extended attributes.
    static func copyHashing(_ source: URL, to destination: Int32) throws -> String {
        defer { close(destination) }
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        _ = fcntl(input, F_RDAHEAD, 1)
        let size = 8 * 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let count = read(input, buffer, size)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            var written = 0
            while written < count {
                let result = write(destination, buffer + written, count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
        // After the data, so the modification date stays the original's.
        _ = fcopyfile(input, destination, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_METADATA))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let first = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let second = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return first.isEqual(second)
    }
}
