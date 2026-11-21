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

    /// Whether photos get a full-size picture ahead of being zoomed (Develop and Loupe make one
    /// once a photo rests): only with a memory budget of at least 1 GB (a 16 GB Mac or more). Its
    /// decode costs a transient ~750 MB beside the photo being edited (30-photo walk in Develop),
    /// too much on an 8 GB Mac; there zooming in sharpens once the full-size render is in.
    var preparesAhead: Bool { RenderMemory.shared.budget >= 1 << 30 }

    /// The full-size picture of `url` with `settings`, if it is the one kept.
    func cached(_ url: URL, settings: DevelopSettings) -> NSImage? {
        guard let last, last.url == url, last.settings == settings else { return nil }
        return last.image
    }

    /// Keeps `image`, rendered elsewhere (Develop's full-size session), as the full-size picture,
    /// unless it is more than half the memory budget (`RenderMemory.budget`: 768 MB on an 8 GB
    /// Mac), so one kept picture never crowds out the photo being edited.
    func store(_ image: NSImage, for url: URL, settings: DevelopSettings) {
        let bytes = Int(image.size.width * image.size.height) * 4
        guard bytes <= RenderMemory.shared.budget / 2 else { last = nil; return }
        last = (url, settings, image)
    }

    /// Renders the full-size picture (or returns the kept one), off the main thread; a render of
    /// the same photo and settings already running is shared.
    func render(_ url: URL, settings: DevelopSettings) async -> NSImage? {
        if let image = cached(url, settings: settings) { return image }
        if let running, running.url == url, running.settings == settings { return await running.task.value }
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            // Its own renderer, let go with this render: the full-size decode and Core Image's
            // working memory for it don't stay in the shared renderer's cache (a 30-photo walk in
            // Develop held about 750 MB more with the shared one).
            let renderer = DevelopRenderer()
            guard let cgImage = renderer.session(for: url, maxPixelSize: nil)?.renderForDisplay(settings)?.image
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
