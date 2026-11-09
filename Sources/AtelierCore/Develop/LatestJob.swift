import Foundation

/// A latest-wins hand-off to a serial background queue: work submitted while earlier work is
/// still waiting replaces it, so a slow job (the histogram and color scope) never builds up a
/// backlog behind fast ones (slider renders, moving through photos). One drain runs at a time
/// and always picks the newest value.
public final class LatestJob<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var draining = false

    public init() {}

    /// Stores the newest value. True when the caller must start a drain (none is running).
    public func submit(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = value
        if draining { return false }
        draining = true
        return true
    }

    /// The newest value not yet taken, or nil, which ends the drain.
    public func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        if value == nil { draining = false }
        return value
    }
}
