import Foundation

/// A timing log of opening photos in Develop: one line per step (waiting for ← → to rest, the
/// camera match and proxy decode, the first render, the histogram, preloading neighbours, the
/// full-size render), with the photo's file, size and whether it is on another volume (the NAS).
/// Written to ~/Documents/Atelier Traces/develop-open-<date>.log so a slow open is explained with
/// numbers instead of guessed at (Rosh, Nov 9, 2026). Cheap: a line per step, written off the
/// main thread.
final class DevelopTimingLog: @unchecked Sendable {
    static let shared = DevelopTimingLog()

    private let queue = DispatchQueue(label: "atelier.develop.timing-log", qos: .utility)
    private var handle: FileHandle?
    /// The log file, once created.
    private(set) var url: URL?
    private let start = CFAbsoluteTimeGetCurrent()

    private init() {
        queue.async { self.open() }
    }

    /// Seconds since an earlier `now()`, in whole milliseconds.
    static func ms(since time: CFAbsoluteTime) -> Int { Int(((CFAbsoluteTimeGetCurrent() - time) * 1000).rounded()) }

    static func now() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    /// "NEF 27.4 MB, local" or "NEF 27.4 MB, on megham", for the open line.
    static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey])
        let size = values?.fileSize.map { String(format: "%.1f MB", Double($0) / 1_000_000) } ?? "? MB"
        let place: String
        if values?.volumeIsLocal == false {
            place = "network volume \(values?.volumeName ?? "?")"
        } else if values?.volumeIsInternal == false {
            place = "external volume \(values?.volumeName ?? "?")"
        } else {
            place = "internal disk"
        }
        return "\(url.lastPathComponent), \(size), \(place)"
    }

    func log(_ assetID: Int64?, _ message: String) {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let line = String(format: "%9.3f  ", elapsed) + (assetID.map { "#\($0)  " } ?? "") + message + "\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            self.handle?.write(data)
        }
    }

    /// A line with the file described (`describe`) between `prefix` and `suffix`. The file's
    /// size and volume are looked up on the log's queue, never on the caller's thread: on a slow
    /// NAS that lookup can block.
    func log(_ assetID: Int64?, describing url: URL, _ prefix: String, _ suffix: String) {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        queue.async {
            let line = String(format: "%9.3f  ", elapsed) + (assetID.map { "#\($0)  " } ?? "")
                + prefix + Self.describe(url) + suffix + "\n"
            guard let data = line.data(using: .utf8) else { return }
            self.handle?.write(data)
        }
    }

    private func open() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("Atelier Traces", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let file = folder.appendingPathComponent("develop-open-\(formatter.string(from: Date())).log")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return }
        self.handle = handle
        url = file
        let header = "Atelier Develop timing log. Seconds since launch, photo id, step. "
            + "A slow open shows which step took the time.\n"
        handle.write(Data(header.utf8))
    }
}
