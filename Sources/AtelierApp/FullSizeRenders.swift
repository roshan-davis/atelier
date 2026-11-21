import AppKit
import AtelierCore

/// The full-size picture of a photo with its settings, for every photo view that shows it past
/// what its preview has pixels for (Develop zoomed in, Loupe zoomed in). One place renders it and
/// keeps the last one, so Develop and Loupe never each render the same photo again, and moving
/// between them zoomed in shows it at once. Develop renders its own on its full-size session (it
/// edits there) and hands the result here; Loupe asks here. Holds one image (about 100 MB for a
/// 24 MP photo), let go on memory pressure, when Develop lets go of full size and when the photo
/// or its settings change.
@MainActor
final class FullSizeRenders {
    static let shared = FullSizeRenders()

    private var last: (url: URL, settings: DevelopSettings, image: NSImage)?
    private var running: (url: URL, settings: DevelopSettings, task: Task<NSImage?, Never>)?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: RenderMemory.pressure, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FullSizeRenders.shared.clear() }
        }
    }

    /// The full-size picture of `url` with `settings`, if it is the one kept.
    func cached(_ url: URL, settings: DevelopSettings) -> NSImage? {
        guard let last, last.url == url, last.settings == settings else { return nil }
        return last.image
    }

    /// Keeps `image`, rendered elsewhere (Develop's full-size session), as the full-size picture.
    func store(_ image: NSImage, for url: URL, settings: DevelopSettings) {
        last = (url, settings, image)
    }

    /// Renders the full-size picture (or returns the kept one), off the main thread; a render of
    /// the same photo and settings already running is shared.
    func render(_ url: URL, settings: DevelopSettings) async -> NSImage? {
        if let image = cached(url, settings: settings) { return image }
        if let running, running.url == url, running.settings == settings { return await running.task.value }
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cgImage = DevelopRenderer.shared.session(for: url, maxPixelSize: nil)?.renderForDisplay(settings)?.image
            else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        running = (url, settings, task)
        let image = await task.value
        if running?.task == task { running = nil }
        if let image { store(image, for: url, settings: settings) }
        return image
    }

    /// Lets go of the kept picture.
    func clear() {
        last = nil
    }
}
