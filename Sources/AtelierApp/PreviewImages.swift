import AppKit

/// Decoded 2560 px previews of the last few photos shown and their neighbours, so stepping to
/// the next photo in Loupe or Develop shows it at once. `NSImage(contentsOf:)` decodes the JPEG
/// lazily on the main thread at first draw, which is what made a newly selected photo lag (AT-019).
@MainActor
final class PreviewImages {
    static let shared = PreviewImages()

    private struct Entry {
        let image: NSImage
        /// The preview file's modification date when decoded; a rebuilt preview is decoded again.
        let modified: Date?
    }

    /// About 18 MB each at 2560 × 1707.
    private let limit = 8
    private var entries: [Int64: Entry] = [:]
    /// Least recently used first.
    private var order: [Int64] = []
    private var inFlight: [Int64: Task<NSImage?, Never>] = [:]

    /// The decoded preview, if it is in memory and its file hasn't changed.
    func cached(_ id: Int64, at url: URL) -> NSImage? {
        guard let entry = entries[id], entry.modified == Self.modified(url) else { return nil }
        touch(id)
        return entry.image
    }

    /// Decodes the preview off the main thread, or returns the one in memory.
    func load(_ id: Int64, at url: URL, priority: TaskPriority = .userInitiated) async -> NSImage? {
        if let image = cached(id, at: url) { return image }
        if let task = inFlight[id] { return await task.value }
        let task = Task.detached(priority: priority) { () -> NSImage? in ThumbnailLoader.decode(url) }
        inFlight[id] = task
        let image = await task.value
        inFlight[id] = nil
        if let image {
            entries[id] = Entry(image: image, modified: Self.modified(url))
            touch(id)
        }
        return image
    }

    /// Decodes these previews in the background, for the photos the arrow keys go to next.
    func prefetch(_ items: [(id: Int64, url: URL)]) {
        for item in items where entries[item.id] == nil && inFlight[item.id] == nil {
            Task { _ = await load(item.id, at: item.url, priority: .utility) }
        }
    }

    private func touch(_ id: Int64) {
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > limit { entries[order.removeFirst()] = nil }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
