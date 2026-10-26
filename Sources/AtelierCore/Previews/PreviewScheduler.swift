import Foundation

/// Builds previews in the background on two lanes, so the grid fills quickly:
/// thumbnails on a fast lane with several workers, 2560 px previews on a slow lane.
/// Requests are de-duplicated, and requests that have not started can be cancelled,
/// for example when a grid cell scrolls off screen.
public final class PreviewScheduler: @unchecked Sendable {
    public typealias Completion = @Sendable (_ assetID: Int64, _ size: PreviewCache.Size) -> Void

    public let cache: PreviewCache

    private struct Key: Hashable {
        var assetID: Int64
        var size: PreviewCache.Size
    }

    private let thumbnailQueue = OperationQueue()
    private let previewQueue = OperationQueue()
    private let lock = NSLock()
    private var pending: [Key: Operation] = [:]
    private var completion: Completion?

    public init(cache: PreviewCache) {
        self.cache = cache
        thumbnailQueue.name = "Atelier thumbnails"
        thumbnailQueue.qualityOfService = .userInitiated
        thumbnailQueue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        previewQueue.name = "Atelier previews"
        previewQueue.qualityOfService = .utility
        previewQueue.maxConcurrentOperationCount = 2
    }

    /// Called on a background thread after each preview is written.
    public func onFinish(_ completion: @escaping Completion) {
        lock.withLock { self.completion = completion }
    }

    /// Queues a preview unless it exists or is already queued. `urgent` moves it to the front,
    /// for the photo open in the loupe or a cell on screen.
    /// With non-neutral `settings` both sizes are rendered developed.
    public func request(_ size: PreviewCache.Size, for assetID: Int64, source: URL, urgent: Bool = false,
                        settings: DevelopSettings? = nil) {
        if cache.has(size, for: assetID) { return }
        let key = Key(assetID: assetID, size: size)
        let operation: BlockOperation? = lock.withLock {
            if let existing = pending[key] {
                if urgent { existing.queuePriority = .veryHigh }
                return nil
            }
            let cache = self.cache
            let operation = BlockOperation { [weak self] in
                if let settings, !settings.isNeutral {
                    if !cache.has(size, for: assetID) {
                        try? cache.generateDeveloped(for: assetID, from: source, settings: settings)
                    }
                } else {
                    switch size {
                    case .thumbnail: try? cache.generateThumbnail(for: assetID, from: source)
                    case .preview: try? cache.generatePreview(for: assetID, from: source)
                    }
                }
                self?.finish(key)
            }
            operation.queuePriority = urgent ? .veryHigh : .normal
            pending[key] = operation
            return operation
        }
        guard let operation else { return }
        (size == .thumbnail ? thumbnailQueue : previewQueue).addOperation(operation)
    }

    /// Drops a request that has not started yet.
    public func cancel(_ size: PreviewCache.Size, for assetID: Int64) {
        let key = Key(assetID: assetID, size: size)
        lock.withLock {
            guard let operation = pending[key], !operation.isExecuting else { return }
            operation.cancel()
            pending[key] = nil
        }
    }

    /// Blocks until queued work is done. For tests.
    public func waitUntilIdle() {
        thumbnailQueue.waitUntilAllOperationsAreFinished()
        previewQueue.waitUntilAllOperationsAreFinished()
    }

    private func finish(_ key: Key) {
        let completion: Completion? = lock.withLock {
            pending[key] = nil
            return self.completion
        }
        completion?(key.assetID, key.size)
    }
}
