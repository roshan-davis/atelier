import Foundation

/// Builds previews in the background on two lanes, so the grid fills quickly:
/// thumbnails on a fast lane with several workers, 2560 px previews on a slow lane.
/// Requests are de-duplicated, and requests that have not started can be cancelled,
/// for example when a grid cell scrolls off screen. A preview that could not be built (an
/// offline or unreadable file) is not tried again until `retryFailed` says something changed.
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
    private var failed: Set<Key> = []
    private var tokens: [Key: UUID] = [:]
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

    /// Called on a background thread after each preview is written; not for failures.
    public func onFinish(_ completion: @escaping Completion) {
        lock.withLock { self.completion = completion }
    }

    /// Queues a preview unless it exists or is already queued. `urgent` moves it to the front,
    /// for the photo open in the loupe or a cell on screen.
    /// With non-neutral `settings` both sizes are rendered developed.
    public func request(_ size: PreviewCache.Size, for assetID: Int64, source: URL, urgent: Bool = false,
                        settings: DevelopSettings? = nil) {
        schedule(size, for: assetID, source: source, urgent: urgent, settings: settings, force: false)
    }

    /// A file changed under a stable asset ID. Rebuild both sizes even when cached, after
    /// any older render finishes, so an old in-flight job cannot overwrite the new pixels.
    public func refresh(for assetID: Int64, source: URL, settings: DevelopSettings? = nil) {
        let earlier: [Operation] = lock.withLock {
            var result: [Operation] = []
            var waiting = pending.filter { $0.key.assetID == assetID }.map(\.value)
            var visited: Set<ObjectIdentifier> = []
            while let operation = waiting.popLast() {
                guard visited.insert(ObjectIdentifier(operation)).inserted else { continue }
                result.append(operation); waiting.append(contentsOf: operation.dependencies)
            }
            return result
        }
        for size in PreviewCache.Size.allCases {
            schedule(size, for: assetID, source: source, urgent: true, settings: settings,
                     force: true, dependencies: earlier)
        }
    }

    private func schedule(_ size: PreviewCache.Size, for assetID: Int64, source: URL,
                          urgent: Bool, settings: DevelopSettings?, force: Bool, dependencies: [Operation] = []) {
        if !force, cache.has(size, for: assetID) { return }
        let key = Key(assetID: assetID, size: size)
        let operation: BlockOperation? = lock.withLock {
            if force { failed.remove(key) }
            if failed.contains(key) { return nil }
            let previous = pending[key]
            if !force, let existing = previous {
                if urgent { existing.queuePriority = .veryHigh }
                return nil
            }
            let cache = self.cache
            let token = UUID()
            let operation = BlockOperation { [weak self] in
                do {
                    if let settings, !settings.isNeutral {
                        if force || !cache.has(size, for: assetID) {
                            try cache.generateDeveloped(for: assetID, from: source, settings: settings)
                        }
                    } else {
                        switch size {
                        case .thumbnail: try cache.generateThumbnail(for: assetID, from: source)
                        case .preview: try cache.generatePreview(for: assetID, from: source)
                        }
                    }
                    self?.finish(key, token: token, written: cache.has(size, for: assetID))
                } catch { self?.finish(key, token: token, written: false) }
            }
            if let previous { operation.addDependency(previous) }
            for dependency in dependencies where dependency !== previous { operation.addDependency(dependency) }
            operation.queuePriority = urgent ? .veryHigh : .normal
            tokens[key] = token
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
            tokens[key] = nil
            pending[key] = nil
        }
    }

    /// Lets failed previews be tried again: those of one photo after its file changed, or all
    /// of them after a drive or network volume came or went.
    public func retryFailed(for assetID: Int64? = nil) {
        lock.withLock {
            if let assetID {
                failed = failed.filter { $0.assetID != assetID }
            } else {
                failed.removeAll()
            }
        }
    }

    /// Blocks until queued work is done. For tests.
    public func waitUntilIdle() {
        thumbnailQueue.waitUntilAllOperationsAreFinished()
        previewQueue.waitUntilAllOperationsAreFinished()
    }

    /// Reporting a failure as a finished preview would make the grid ask for it again at once,
    /// and the library would refresh in a loop for as long as the file can't be read.
    private func finish(_ key: Key, token: UUID, written: Bool) {
        let completion: Completion? = lock.withLock {
            guard tokens[key] == token else { return nil }
            tokens[key] = nil
            pending[key] = nil
            guard written else {
                failed.insert(key)
                return nil
            }
            return self.completion
        }
        completion?(key.assetID, key.size)
    }
}
