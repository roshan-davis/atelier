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
    /// Then a Tone Curve preset and a Color Grading preset (AT-057), each changing only its panel.
    public var toneCurvePreset: DevelopPreset?
    public var colorGradingPreset: DevelopPreset?

    public init(mode: ImportMode = .reference, target: ImportTarget = .newGroup(name: ""),
                keywords: [String] = [], buildPreviews: Bool = true, developPreset: DevelopPreset? = nil,
                toneCurvePreset: DevelopPreset? = nil, colorGradingPreset: DevelopPreset? = nil) {
        self.mode = mode
        self.target = target
        self.keywords = keywords
        self.buildPreviews = buildPreviews
        self.developPreset = developPreset
        self.toneCurvePreset = toneCurvePreset
        self.colorGradingPreset = colorGradingPreset
    }

    /// What import applies, in order, with the history step each one records: the Develop
    /// preset ("Import Preset: Portra 400"), then the Tone Curve preset ("Import Tone Curve
    /// Preset: Matte"), then the Color Grading preset. A later one wins where they overlap, as a
    /// preset applied by hand afterwards would.
    public var developSteps: [(name: String, preset: DevelopPreset)] {
        var steps: [(String, DevelopPreset)] = []
        if let developPreset { steps.append(("Import Preset: \(developPreset.name)", developPreset)) }
        if let toneCurvePreset {
            steps.append(("Import \(SectionPresetKind.toneCurve.title) Preset: \(toneCurvePreset.name)", toneCurvePreset))
        }
        if let colorGradingPreset {
            steps.append(("Import \(SectionPresetKind.colorGrading.title) Preset: \(colorGradingPreset.name)",
                          colorGradingPreset))
        }
        return steps
    }

    /// The settings a new photo starts with, and its history, one step per preset; nil when
    /// import applies nothing.
    public func initialDevelop() -> (settings: DevelopSettings, history: DevelopHistory)? {
        let steps = developSteps
        guard !steps.isEmpty else { return nil }
        var settings = DevelopSettings.neutral
        var history = DevelopHistory()
        for step in steps {
            let previous = settings
            settings = step.preset.applied(to: settings)
            history.record(step.name, settings: settings, previous: previous)
        }
        return (settings, history)
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
    /// New photos that received recovered settings or an import preset; auto-write only these.
    public var developedAssetIDs: [Int64] = []
    /// The import entry the photos were added to.
    public var importGroupId: Int64?
    /// Each source file's photo, new or already in the catalog.
    public var assetIDsBySource: [URL: Int64] = [:]
    /// The size of every file to import, and of those handled so far.
    public var totalBytes: Int64 = 0
    public var bytesDone: Int64 = 0
    /// The file most recently started, and the one most recently finished (cataloged or not).
    public var currentFile: URL?
    public var finishedFile: URL?

    public init() {}
}

enum ImportOutcome {
    case imported(Int64, URL, hasSettings: Bool)
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
            // Independent of LaunchServices/UTI registration, including explicitly selected
            // project descendants. Private sources and saved generations are never imports.
            if source.pathComponents.contains(where: { ($0 as NSString).pathExtension.lowercased() == "atelierhdr" }) { continue }
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
                if url.pathExtension.lowercased() == "atelierhdr" {
                    enumerator?.skipDescendants()
                    continue
                }
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isFile && MetadataReader.isSupported(url) { files.append(url) }
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Files are handled a few at a time (reading, hashing and copying overlap), and nothing is
    /// rendered until every file is cataloged: thumbnails and previews are queued at the end, so
    /// they don't compete with the copy for the disk.
    ///
    /// With a `stager`, files it already copied (or hashed) while the user culled are moved into
    /// place instead of copied again; its leftovers are discarded at the end.
    public func run(sources: [URL], options: ImportOptions, stager: ImportStager? = nil,
                    progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async -> ImportProgress {
        await stager?.stop()
        // In copy mode every file goes through a staged copy (made ahead or now), so a slow
        // source is read once, start to end.
        let staging = stager ?? Self.copyStager(for: options.mode)
        defer { staging?.discard() }
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
                group.addTask { (index, Result { try self.importFile(files[index], options: options, stager: staging) }) }
            }
            for await (index, outcome) in group {
                let file = files[index]
                do {
                    let assetID: Int64
                    switch try outcome.get() {
                    case .imported(let id, let url, let hasSettings):
                        state.imported += 1
                        if hasSettings { state.developedAssetIDs.append(id) }
                        imported.append((index, id, url))
                        assetID = id
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
                state.finishedFile = file
                if !Task.isCancelled, next < files.count {
                    let index = next
                    next += 1
                    state.currentFile = files[index]
                    group.addTask { (index, Result { try self.importFile(files[index], options: options, stager: staging) }) }
                }
                progress(state)
            }
        }
        imported.sort { $0.index < $1.index }
        state.importedAssetIDs = imported.map(\.id)

        if options.buildPreviews, let scheduler {
            let jobs = imported.map { photo in
                (photo, try? catalog.developSettings(for: photo.id))
            }
            for (photo, settings) in jobs {
                scheduler.request(.thumbnail, for: photo.id, source: photo.url, settings: settings)
            }
            for (photo, settings) in jobs {
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

    /// The stager an import makes for itself in copy mode, when culling didn't make one.
    static func copyStager(for mode: ImportMode) -> ImportStager? {
        if case .copy = mode { return ImportStager(mode: mode) }
        return nil
    }

    /// Files handled at once. Copies are bound by the card or drive, hashing a referenced file
    /// by the CPU too.
    public static func workers(for mode: ImportMode) -> Int {
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

    func importFile(_ source: URL, options: ImportOptions, stager: ImportStager? = nil,
                    registration: ((Database, Int64) throws -> Void)? = nil) throws -> ImportOutcome {
        // Re-importing a referenced folder should not re-hash files that are already cataloged.
        if options.mode == .reference, registration == nil, let existing = try existingAssetID(for: source) {
            return .existing(existing)
        }

        try Task.checkCancellation()
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(sourceValues.fileSize ?? 0)
        var staged = stager?.take(source, size: size, modified: sourceValues.contentModificationDate)
        if case .copy = options.mode, staged?.url == nil, let stager,
           let copy = try stager.copy(source, size: size, modified: sourceValues.contentModificationDate) {
            staged = copy
        }
        // From the local copy when there is one: reading a raw file's metadata takes many small
        // reads, each a round trip to the NAS.
        let metadata = MetadataReader.read(staged?.url ?? source, sidecarFor: source)
        // Fail this file visibly before copying if recovery data is unreadable. Never
        // substitute a preset or neutral edits for damaged/unsupported recovery settings.
        let recovery = try XMPSidecar.readDevelopRecovery(for: source)
        let recovered = recovery?.settings
        let initialDevelop = options.initialDevelop()
        let initialSettings = recovered ?? initialDevelop?.settings
        let hash: String
        var fileURL = source

        if case let .copy(root, eventName) = options.mode {
            let date = metadata.captureTime ?? sourceValues.contentModificationDate ?? Date()
            let directory = Self.destinationDirectory(root: root, date: date, eventName: eventName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = try Self.copyVerified(source, into: directory, staged: staged)
            fileURL = copy.url
            hash = copy.hash
        } else {
            hash = try staged?.hash ?? FileHasher.sha256(of: source)
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
            try Catalog.ensureLocation(for: volumeRecord, db)

            var folder = try Folder
                .filter(Column("volumeId") == volumeRecord.id! && Column("relativePath") == relativeFolder)
                .fetchOne(db)
                ?? Folder(id: nil, volumeId: volumeRecord.id!, relativePath: relativeFolder)
            if folder.id == nil { try folder.insert(db) }

            if let existing = try Int64.fetchOne(db, sql: """
                SELECT id FROM asset WHERE folderId = ? AND filename = ? AND virtualCopyOf IS NULL
                """,
                                                 arguments: [folder.id!, filename]) {
                try registration?(db, existing)
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
            // Notes saved in the sidecar's `atelier:Notes` (AT-058) come back with the photo.
            for note in metadata.xmp.notes ?? [] {
                var record = note.record(assetID: assetID)
                try record.insert(db)
            }
            if let settings = initialSettings,
               let versionID = try Catalog.masterVersionID(db, assetID: assetID, create: true) {
                var history = recovery?.history ?? DevelopHistory()
                if recovered != nil, recovery?.history == nil {
                    history.steps = [DevelopHistory.Step(name: "Recovered from XMP", settings: settings)]
                    history.position = 0
                } else if recovered == nil, let initialDevelop {
                    history = initialDevelop.history
                }
                try DevelopSettingsRecord(versionId: versionID, schemaVersion: settings.schemaVersion,
                    json: settings.encoded(), historyJson: history.encoded(), updatedAt: Date()).save(db)
                try AssetMetadata.filter(key: assetID).updateAll(db, Column("xmpDirty").set(to: true))
            }
            try registration?(db, assetID)
            return .imported(assetID, importedURL, hasSettings: initialSettings != nil)
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
    /// same APFS volume the copy is a clone, which takes no time or space. A copy `staged` ahead
    /// (already verified) is moved into place instead.
    static func copyVerified(_ source: URL, into directory: URL,
                             staged: ImportStager.Staged? = nil) throws -> (url: URL, hash: String) {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        /// Only needed when the name is taken, to tell an earlier copy from a different photo.
        var sourceHash: String? = staged?.hash
        // Creating the file exclusively claims the name, so two copies never pick the same one.
        var reserved = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        while reserved < 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let hash = try sourceHash ?? FileHasher.sha256(of: source)
            sourceHash = hash
            if (try? FileHasher.sha256(of: candidate)) == hash {
                if let copy = staged?.url { try? fm.removeItem(at: copy) }
                return (candidate, hash)
            }
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
            reserved = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }

        let hash: String
        do {
            // A copy made ahead was verified when it was made; moving it in is a rename.
            let moved = staged?.url.map { Self.moveStaged($0, over: candidate, reservation: reserved) } ?? false
            if let staged, moved {
                hash = staged.hash
            } else if Self.sameVolume(source, directory) {
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
            guard try moved || FileHasher.sha256(of: candidate) == hash else {
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
    static func copyHashing(_ source: URL, to destination: Int32,
                            progress: ((Int64) -> Void)? = nil, shouldPause: (() -> Bool)? = nil,
                            shouldStop: (() -> Bool)? = nil) throws -> String {
        defer { close(destination) }
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        _ = fcntl(input, F_RDAHEAD, 1)
        let size = 8 * 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            // A background copy steps aside while the photo being opened reads (AT-079c).
            while shouldPause?() == true {
                try Task.checkCancellation()
                usleep(50_000)
            }
            if shouldStop?() == true { throw CancellationError() }
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
            copied += Int64(count)
            progress?(copied)
        }
        // After the data, so the modification date stays the original's.
        _ = fcopyfile(input, destination, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_METADATA))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Moves a staged copy over the placeholder that reserved its name, and closes the
    /// placeholder. False when it can't be moved (another volume), with the placeholder still open.
    static func moveStaged(_ copy: URL, over candidate: URL, reservation: Int32) -> Bool {
        guard rename(copy.path, candidate.path) == 0 else { return false }
        close(reservation)
        return true
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let first = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let second = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return first.isEqual(second)
    }
}
