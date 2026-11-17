import CoreImage
import Foundation

/// The catalog's smart previews (AT-079d): one DNG per photo (virtual copies share their master's)
/// in the catalog package's "Smart Previews" folder, always on this Mac, and each camera model's
/// white table (`CameraWhite`) in its "Cameras" subfolder. Develop edits a photo from its smart
/// preview while the original is offline; nothing else uses one in its place.
public final class SmartPreviewStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    /// Camera models whose white table is being fitted (one fit per model at a time).
    private var fitting: Set<String> = []
    private var whites: [String: CameraWhite] = [:]

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: camerasFolder(root), withIntermediateDirectories: true)
    }

    /// The smart preview of a photo's file (pass the master's id: `Catalog.originalID(for:)`).
    public func url(for fileID: Int64) -> URL {
        root.appendingPathComponent("\(fileID).dng")
    }

    public func has(_ fileID: Int64) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileID).path)
    }

    /// The ids among `fileIDs` that have one.
    public func existing(among fileIDs: [Int64]) -> Set<Int64> {
        Set(fileIDs.filter(has))
    }

    /// Bytes used by every smart preview and white table.
    public func totalBytes() -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Makes (or replaces) the smart preview of `fileID` from its original, first fitting the
    /// camera's white table if this is the model's first photo. Throws when the original can't be
    /// decoded. Background work: about 0.15 s, plus about 20 s once per camera model.
    public func make(_ fileID: Int64, from original: URL, cameraMatch: CameraMatch,
                     context: CIContext = CIContext(options: [.cacheIntermediates: false]),
                     shouldStop: () -> Bool = { false }) throws {
        let temporary = root.appendingPathComponent(".\(fileID)-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try SmartPreviewDNG.make(from: original, to: temporary, cameraMatch: cameraMatch, context: context)
        guard let info = SmartPreviewInfo.read(temporary) else { throw CocoaError(.fileWriteUnknown) }
        guard ensureWhite(for: info.camera, from: original, context: context, shouldStop: shouldStop) != nil else {
            if shouldStop() { throw CocoaError(.userCancelled) }
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "Atelier couldn't measure how this camera's white balance works from this photo."])
        }
        let destination = url(for: fileID)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// Discards the smart previews of `fileIDs` (Library > Previews > Discard Smart Previews).
    /// White tables stay: they are tiny and cost a fit to make again.
    @discardableResult
    public func discard(_ fileIDs: [Int64]) -> Int {
        var removed = 0
        for id in fileIDs where (try? FileManager.default.removeItem(at: url(for: id))) != nil { removed += 1 }
        return removed
    }

    // MARK: White tables

    /// The camera's white table: in memory, else from its file, else nil.
    public func white(for camera: String) -> CameraWhite? {
        if let known = lock.withLock({ whites[camera] }) { return known }
        guard let data = try? Data(contentsOf: whiteURL(camera)),
              let white = try? JSONDecoder().decode(CameraWhite.self, from: data), white.isCurrent else { return nil }
        lock.withLock { whites[camera] = white }
        return white
    }

    /// The camera's white table, fitted from `raw` when there is none yet. Nil when cancelled or
    /// the fit failed; waits when another photo of the model is fitting it.
    func ensureWhite(for camera: String, from raw: URL, context: CIContext, shouldStop: () -> Bool) -> CameraWhite? {
        while true {
            if let known = white(for: camera) { return known }
            let mine = lock.withLock { fitting.insert(camera).inserted }
            if mine { break }
            if shouldStop() { return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
        defer { lock.withLock { _ = fitting.remove(camera) } }
        guard let white = CameraWhite.fit(from: raw, camera: camera, context: context, shouldStop: shouldStop),
              let data = try? JSONEncoder().encode(white) else { return nil }
        try? data.write(to: whiteURL(camera), options: .atomic)
        lock.withLock { whites[camera] = white }
        return white
    }

    func whiteURL(_ camera: String) -> URL {
        Self.whiteURL(camera, root: root)
    }

    static func whiteURL(_ camera: String, root: URL) -> URL {
        let safe = camera.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return camerasFolder(root).appendingPathComponent("\(safe).json")
    }

    /// The white table for a smart preview file, from the folder it is in (for `DevelopSession`).
    static func white(forPreview url: URL, camera: String) -> CameraWhite? {
        guard let data = try? Data(contentsOf: whiteURL(camera, root: url.deletingLastPathComponent())),
              let white = try? JSONDecoder().decode(CameraWhite.self, from: data), white.isCurrent else { return nil }
        return white
    }
}

private func camerasFolder(_ root: URL) -> URL {
    root.appendingPathComponent("Cameras", isDirectory: true)
}

extension Catalog {
    /// The catalog package's smart previews folder; nil for an in-memory catalog.
    public var smartPreviewsURL: URL? { packageURL?.appendingPathComponent("Smart Previews", isDirectory: true) }
}
