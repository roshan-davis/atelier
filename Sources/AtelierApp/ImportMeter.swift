import AtelierCore
import Foundation

/// Turns the importer's per-file progress into what the Import dialog shows, cheaply enough to
/// run after every file: the files done are kept as a growing set (not rebuilt each time),
/// updates go out a few times a second, and the speed is measured over the last few seconds.
///
/// A recent speed matters after culling: files copied ahead are only moved into place, so the
/// first part of an import goes by in a moment. An average since the start would then show a
/// speed the card can't keep up and a time left that is far too short.
final class ImportMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Set<String> = []
    private var samples: [(time: Date, bytes: Int64)] = []
    private var lastSent = Date.distantPast

    private static let window: TimeInterval = 6
    private static let interval: TimeInterval = 0.15

    /// nil when the dialog was updated too recently to need it again.
    func status(for progress: ImportProgress, copying: Bool) -> ImportStatus? {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let file = progress.finishedFile, progress.assetIDsBySource[file] != nil {
            done.insert(file.standardizedFileURL.path)
        }
        samples.append((now, progress.bytesDone))
        // Keep one sample from before the window, so a slow file still has something to measure from.
        while samples.count > 2, now.timeIntervalSince(samples[1].time) > Self.window { samples.removeFirst() }
        let isLast = progress.processed >= progress.total
        guard isLast || now.timeIntervalSince(lastSent) >= Self.interval else { return nil }
        lastSent = now
        var speed: Double?
        if let first = samples.first, now.timeIntervalSince(first.time) >= 1 {
            speed = Double(progress.bytesDone - first.bytes) / now.timeIntervalSince(first.time)
        }
        return LibraryModel.importStatus(progress, copying: copying, speed: speed, doneFiles: done)
    }
}
