import Foundation

/// TEMPORARY: logs what the photo view does when a photo opens, to find why it jumps.
/// Writes to ~/Documents/atelier-zoom-trace.log. Remove before merging.
enum ZoomTrace {
    private static let lock = NSLock()
    private static let start = Date()
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/atelier-zoom-trace.log")
    private static var handle: FileHandle? = {
        try? Data().write(to: url)
        return try? FileHandle(forWritingTo: url)
    }()

    static func log(_ message: @autoclosure () -> String) {
        let line = String(format: "%8.1f ", Date().timeIntervalSince(start) * 1000) + message() + "\n"
        lock.withLock { handle?.write(Data(line.utf8)) }
    }

    static func size(_ s: CGSize?) -> String {
        guard let s else { return "nil" }
        return String(format: "%.1fx%.1f", s.width, s.height)
    }
}
