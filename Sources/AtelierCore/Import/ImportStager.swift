import Darwin
import Foundation

/// Copies an import's files to the destination drive ahead of time, while the user culls, so
/// Import only has to move each finished copy into its dated folder. A referenced import, or a
/// copy on the same volume (a clone, which takes no time), is only hashed ahead.
///
/// Copies go to a hidden folder in the library root (`.Atelier Staging`), on the same volume as
/// their final place, so moving one in is a rename. Each is verified by hash when it is made.
/// The importer takes what is ready (`stop()` first), copies the rest itself, and `discard()`s
/// the folder at the end; going back or closing the dialog discards it too.
public final class ImportStager: @unchecked Sendable {
    /// A file done ahead: its verified copy (nil when only hashed), and the source as it was,
    /// so a file that changed since is copied again.
    public struct Staged: Sendable {
        public let url: URL?
        public let hash: String
        let size: Int64
        let modified: Date?

        func matches(size: Int64, modified: Date?) -> Bool {
            self.size == size && self.modified == modified
        }
    }

    public struct Progress: Sendable, Equatable {
        public var done = 0
        public var total = 0
        public var bytesDone: Int64 = 0
        public var totalBytes: Int64 = 0
        public var copying = false
        public var isFinished: Bool { total > 0 && done >= total }
    }

    let mode: ImportMode
    /// This import's own folder inside `.Atelier Staging`, in copy mode.
    let directory: URL?
    private let lock = NSLock()
    private var staged: [String: Staged] = [:]
    private var stopping = false
    private var task: Task<Void, Never>?

    /// Copies even on the destination's own volume (where a clone would do), for tests.
    let copiesOnSameVolume: Bool

    public convenience init(mode: ImportMode) {
        self.init(mode: mode, copiesOnSameVolume: false)
    }

    init(mode: ImportMode, copiesOnSameVolume: Bool) {
        self.mode = mode
        self.copiesOnSameVolume = copiesOnSameVolume
        if case let .copy(root, _) = mode {
            directory = Self.stagingRoot(in: root).appendingPathComponent(UUID().uuidString, isDirectory: true)
        } else {
            directory = nil
        }
    }

    static func stagingRoot(in root: URL) -> URL {
        root.appendingPathComponent(".Atelier Staging", isDirectory: true)
    }

    /// Starts on every file in `sources`, a few at a time. Calls `progress` after each file.
    public func start(sources: [URL], workers: Int = 2,
                      progress: @escaping @Sendable (Progress) -> Void = { _ in }) {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil, !stopping else { return }
        let directory = self.directory
        task = Task.detached(priority: .utility) { [self] in
            if let directory {
                // Left over from an import that never finished (the app quit mid-cull).
                let root = directory.deletingLastPathComponent()
                for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: old)
                }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    return
                }
            }
            let files = Importer.collectFiles(from: sources)
            let sizes = files.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            // On the library's own volume a file is only hashed ahead (Import clones it).
            let copying = directory.map { directory in
                copiesOnSameVolume || !(files.first.map { Importer.sameVolume($0, directory) } ?? false)
            } ?? false
            var state = Progress(total: files.count, totalBytes: sizes.reduce(0, +), copying: copying)
            progress(state)
            await withTaskGroup(of: Int64.self) { group in
                var next = 0
                while next < min(max(1, workers), files.count) {
                    let index = next
                    group.addTask { self.stage(files[index]); return sizes[index] }
                    next += 1
                }
                for await bytes in group {
                    state.done += 1
                    state.bytesDone += bytes
                    progress(state)
                    if next < files.count, !isStopping, !Task.isCancelled {
                        let index = next
                        group.addTask { self.stage(files[index]); return sizes[index] }
                        next += 1
                    }
                }
            }
        }
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    /// Copies or hashes one file. A failure is left for the importer, which tries again and
    /// reports it.
    private func stage(_ source: URL) {
        guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let size = Int64(values.fileSize ?? 0)
        let modified = values.contentModificationDate
        var copy: URL?
        let hash: String
        do {
            if let directory, copiesOnSameVolume || !Importer.sameVolume(source, directory) {
                let ext = source.pathExtension
                let url = directory.appendingPathComponent(ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)")
                let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                guard fd >= 0 else { return }
                do {
                    hash = try Importer.copyHashing(source, to: fd)
                    guard try FileHasher.sha256(of: url) == hash else { throw CocoaError(.fileWriteUnknown) }
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                copy = url
            } else {
                hash = try FileHasher.sha256(of: source)
            }
        } catch {
            return
        }
        lock.lock()
        staged[Self.key(source)] = Staged(url: copy, hash: hash, size: size, modified: modified)
        lock.unlock()
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Stops starting files and waits for those under way, so everything done is ready to use.
    public func stop() async {
        lock.lock()
        stopping = true
        let task = self.task
        lock.unlock()
        await task?.value
    }

    /// Waits for every file to be done, for tests.
    func waitUntilDone() async {
        lock.lock()
        let task = self.task
        lock.unlock()
        await task?.value
    }

    /// What was done ahead for `source`, if the file hasn't changed since. The copy, if any,
    /// is handed over: the caller moves it into place or it goes with `discard()`.
    func take(_ source: URL, size: Int64, modified: Date?) -> Staged? {
        lock.lock()
        defer { lock.unlock() }
        guard let found = staged.removeValue(forKey: Self.key(source)), found.matches(size: size, modified: modified) else {
            return nil
        }
        return found
    }

    /// Stops at once and removes every copy that wasn't used. The task returned ends when
    /// they are gone.
    @discardableResult
    public func discard() -> Task<Void, Never> {
        lock.lock()
        stopping = true
        let task = self.task
        staged = [:]
        lock.unlock()
        task?.cancel()
        let directory = self.directory
        return Task.detached(priority: .utility) {
            await task?.value
            guard let directory else { return }
            try? FileManager.default.removeItem(at: directory)
            // The staging folder itself, once no import is using it.
            let root = directory.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty ?? false {
                try? FileManager.default.removeItem(at: root)
            }
        }
    }
}
