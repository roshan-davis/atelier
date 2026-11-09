import AppKit
import Foundation
import QuartzCore

/// TEMPORARY diagnostic for the Develop drag lag (Rosh, Nov 9, 2026). Not for main.
///
/// Records, while the app runs, to `~/Documents/Atelier Traces/develop-<time>.log`:
/// - `stall`: every main-thread busy span over 16 ms, with the marks that happened inside it
///   (which publish, save or refresh ran), so we can see what holds the main thread;
/// - `input`: how old each drag event is when its handler runs (event time to now), which is
///   how far a control trails the mouse;
/// - `edit`/`render`/`shown`: time from an edit to its render starting, the render itself, and
///   the photo on screen;
/// - `save`/`rows`/`previews`: the autosave and the library refreshes it sets off;
/// - `bodies`: how many times key views were re-evaluated each second.
/// Writing happens on a background queue; the cost on the main thread is a few appends.
enum DevelopTrace {
    private static let start = CACurrentMediaTime()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var marks: [String] = []
    nonisolated(unsafe) private static var bodies: [String: Int] = [:]
    nonisolated(unsafe) private static var busySince: CFTimeInterval?
    nonisolated(unsafe) private static var observer: CFRunLoopObserver?
    nonisolated(unsafe) private static var timer: Timer?
    private static let queue = DispatchQueue(label: "atelier.trace", qos: .utility)
    nonisolated(unsafe) private static var fileURL: URL?

    static var now: Double { (CACurrentMediaTime() - start) * 1000 }

    /// Starts tracing. Called once at launch.
    @MainActor static func install() {
        guard observer == nil else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Atelier Traces", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent("develop-\(formatter.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileURL = url
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        log("start build=\(build) cores=\(ProcessInfo.processInfo.activeProcessorCount)")

        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { _, activity in
            let time = CACurrentMediaTime()
            if activity == .afterWaiting {
                busySince = time
            } else if let since = busySince {
                busySince = nil
                let busy = (time - since) * 1000
                lock.lock()
                let inside = marks
                marks.removeAll()
                lock.unlock()
                if busy > 16 {
                    log(String(format: "stall %.1f ms [%@]", busy, summarize(inside)))
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in flush() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Something happened on the main thread worth naming inside a stall.
    static func mark(_ name: String) {
        lock.lock()
        marks.append(name)
        lock.unlock()
    }

    /// A line in the log, timestamped in ms since launch.
    static func log(_ text: String) {
        let line = String(format: "%10.1f ", now) + text
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    /// A drag event handled now; `eventTime` is when the mouse moved.
    static func input(_ control: String, eventTime: Date) {
        let age = Date().timeIntervalSince(eventTime) * 1000
        log(String(format: "input %@ age %.1f ms", control, age))
        mark("input \(control)")
    }

    /// A view's body ran. Counted per second.
    static func body(_ name: String) {
        lock.lock()
        bodies[name, default: 0] += 1
        lock.unlock()
    }

    /// Times `work` on the current thread and logs it.
    @discardableResult
    static func time<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let begin = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - begin) * 1000
            log(String(format: "%@ %.1f ms%@", name, ms, Thread.isMainThread ? " (main)" : ""))
            if Thread.isMainThread { mark(name) }
        }
        return try work()
    }

    private static func summarize(_ marks: [String]) -> String {
        var counts: [(String, Int)] = []
        for mark in marks {
            if let index = counts.firstIndex(where: { $0.0 == mark }) { counts[index].1 += 1 } else { counts.append((mark, 1)) }
        }
        return counts.map { $0.1 > 1 ? "\($0.0) x\($0.1)" : $0.0 }.joined(separator: ", ")
    }

    private static func flush() {
        lock.lock()
        if !bodies.isEmpty {
            let text = bodies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            lines.append(String(format: "%10.1f ", now) + "bodies/s " + text)
            bodies.removeAll()
        }
        let batch = lines
        lines.removeAll()
        lock.unlock()
        guard !batch.isEmpty, let url = fileURL else { return }
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((batch.joined(separator: "\n") + "\n").utf8))
        }
    }
}
