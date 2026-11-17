import Foundation

/// Block-based notification observers kept together and removed when their owner goes, or on
/// `removeAll()` (AT-076 M4). Apple's rule for `addObserver(forName:object:queue:using:)` is to
/// keep the returned token and remove it; an owner holds one of these instead of loose tokens.
public final class NotificationObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    public init() {}

    deinit { removeAll() }

    /// Calls `block` on `queue` (the main queue unless given) for each `name` posted to `center`.
    public func observe(_ name: Notification.Name, center: NotificationCenter = .default, object: Any? = nil,
                        queue: OperationQueue? = .main, using block: @escaping @Sendable (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: queue, using: block)
        lock.withLock { tokens.append((center, token)) }
    }

    public var count: Int { lock.withLock { tokens.count } }

    public func removeAll() {
        let removed = lock.withLock {
            defer { tokens = [] }
            return tokens
        }
        for (center, token) in removed { center.removeObserver(token) }
    }
}
