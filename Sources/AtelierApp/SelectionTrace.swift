import AppKit

/// TEMPORARY (AT-019 investigation, remove before merge): logs what happens between choosing a
/// photo and its first frame to ~/Documents/atelier-selection-trace.log, with milliseconds since
/// the choice, plus every main-thread stall over 16 ms in the two seconds after it.
@MainActor
enum SelectionTrace {
    private static var chosenAt: CFAbsoluteTime = 0
    private static var observer: CFRunLoopObserver?
    private static var wokeAt: CFAbsoluteTime = 0
    private static let queue = DispatchQueue(label: "atelier.selection-trace")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/atelier-selection-trace.log")

    static func chose(_ id: Int64?, mode: String) {
        chosenAt = CFAbsoluteTimeGetCurrent()
        write("\n=== chose \(id.map(String.init) ?? "nil") in \(mode) at \(Date())")
        installObserver()
    }

    static func mark(_ text: String) {
        guard chosenAt > 0 else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - chosenAt) * 1000
        guard ms < 5000 else { return }
        write(String(format: "%7.1f ms  %@", ms, text))
    }

    nonisolated static func markOffMain(_ text: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { mark(text + " (reported from background)") } }
    }

    private static func installObserver() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                if activity == .afterWaiting {
                    wokeAt = now
                } else if wokeAt > 0 {
                    let busy = (now - wokeAt) * 1000
                    if busy > 16, (now - chosenAt) < 2 { mark(String(format: "main thread busy %.0f ms", busy)) }
                    wokeAt = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private static func write(_ line: String) {
        let url = self.url
        queue.async {
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
