import CryptoKit
import Foundation

/// Downloads an optional model file (Fine Edges, Depth Range) and checks it against the SHA-256
/// it is pinned to, so every model download in Settings works the same way.
public enum ModelDownload {
    public struct ChecksumMismatch: LocalizedError {
        public var errorDescription: String? {
            "The downloaded model isn't the expected file, so it wasn't installed."
        }
    }

    /// Downloads `url`, checks it is `sha256` and moves it to `destination` (replacing what was
    /// there). `progress` gets 0...1 on any thread. Cancelling the task stops the download.
    public static func fetch(_ url: URL, sha256: String, to destination: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let holder = ObservationHolder()
        let downloaded: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                    holder.observation = nil
                    if let error { return continuation.resume(throwing: error) }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        return continuation.resume(throwing: URLError(.badServerResponse))
                    }
                    guard let file else { return continuation.resume(throwing: URLError(.cannotOpenFile)) }
                    // The file is removed when this returns: move it somewhere of ours first.
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + destination.pathExtension)
                    do {
                        try FileManager.default.moveItem(at: file, to: kept)
                        continuation.resume(returning: kept)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                holder.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                    progress(value.fractionCompleted)
                }
                holder.task = task
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        guard try checksum(of: downloaded) == sha256 else { throw ChecksumMismatch() }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
    }

    /// The file's SHA-256, lowercase hex, read in 4 MB pieces.
    public static func checksum(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let piece = try handle.read(upToCount: 4 << 20), !piece.isEmpty { hash.update(data: piece) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Application Support/Atelier/Models, where downloaded models live.
    public static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Atelier/Models", isDirectory: true)
    }

    private final class ObservationHolder: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask?
    }
}
