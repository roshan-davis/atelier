import AppKit
import Combine
import QuartzCore

/// Diagnostics for jerky trackpad zoom, not for merging. While a pinch or scroll is under way in
/// Loupe or Develop, and for 3 s after it, logs frame timing, main-thread stalls, renders and
/// SwiftUI updates to ~/Documents/Atelier-zoom-trace.log.
@MainActor
enum ZoomTrace {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Atelier-zoom-trace.log")
    private static var handle: FileHandle?
    private static var cancellables: [AnyCancellable] = []
    private static var observer: CFRunLoopObserver?
    private static var busySince: CFTimeInterval?
    private static var stopWork: DispatchWorkItem?
    private static var gestureStart: CFTimeInterval = 0
    private static var counts: [String: Int] = [:]
    private static var lastFrame: CFTimeInterval?
    private static var frameCount = 0
    private static var droppedFrames = 0
    private static var longestGap: CFTimeInterval = 0
    private static var stalls: [Double] = []
    private(set) static var isRecording = false

    static func log(_ text: String) {
        if handle == nil { open() }
        let time = isRecording ? CACurrentMediaTime() - gestureStart : 0
        handle?.write(Data((String(format: "%8.3f  ", time) + text + "\n").utf8))
    }

    /// Called on every zoom or scroll event: starts recording, and stops 3 s after the last one.
    static func touch(_ kind: String) {
        if !isRecording {
            isRecording = true
            gestureStart = CACurrentMediaTime()
            counts = [:]
            lastFrame = nil
            frameCount = 0
            droppedFrames = 0
            longestGap = 0
            stalls = []
            installObserver()
            log("BEGIN \(kind)")
        }
        stopWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { finish() } }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Counts an event, and logs it while recording.
    static func count(_ name: String, _ detail: @autoclosure () -> String = "") {
        guard isRecording else { return }
        counts[name, default: 0] += 1
        let detail = detail()
        log(detail.isEmpty ? name : "\(name): \(detail)")
    }

    static func milliseconds(since start: CFTimeInterval) -> String {
        String(format: "%.2f ms", (CACurrentMediaTime() - start) * 1000)
    }

    /// Counts how often an observable object tells SwiftUI it changed.
    static func watch(_ publisher: ObservableObjectPublisher, _ name: String) {
        publisher.sink { _ in
            MainActor.assumeIsolated { count(name) }
        }
        .store(in: &cancellables)
    }

    /// One display refresh, from a display link on the main thread.
    static func frame(_ timestamp: CFTimeInterval, interval: CFTimeInterval) {
        guard isRecording else { return }
        frameCount += 1
        if let lastFrame, interval > 0 {
            let gap = timestamp - lastFrame
            longestGap = max(longestGap, gap)
            let missed = Int((gap / interval).rounded()) - 1
            if missed > 0 {
                droppedFrames += missed
                log(String(format: "DROPPED %ld frame(s): %.1f ms between frames (refresh %.1f ms)",
                           missed, gap * 1000, interval * 1000))
            }
        }
        lastFrame = timestamp
    }

    private static func finish() {
        guard isRecording else { return }
        let duration = CACurrentMediaTime() - gestureStart
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        log(String(format: "END after %.1f s: %ld frames, %ld dropped, longest gap %.1f ms, %ld main-thread stalls over 8 ms (longest %.1f ms)",
                   duration, frameCount, droppedFrames, longestGap * 1000, stalls.count, stalls.max() ?? 0))
        log("counts: \(summary)")
        isRecording = false
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        busySince = nil
    }

    private static func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        let screen = NSScreen.main
        let header = "\n=== Atelier \(build) build, \(Date()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
            + "screen \(screen?.maximumFramesPerSecond ?? 0) Hz at \(screen?.backingScaleFactor ?? 0)x ===\n"
        handle?.write(Data(header.utf8))
    }

    /// Logs each stretch over 8 ms where the main thread runs without waiting for events.
    private static func installObserver() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated { runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private static func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity.contains(.afterWaiting) {
            busySince = now
        } else if let since = busySince {
            busySince = nil
            let busy = (now - since) * 1000
            if busy > 8 {
                stalls.append(busy)
                log(String(format: "MAIN THREAD BUSY %.1f ms", busy))
            }
        }
    }
}
