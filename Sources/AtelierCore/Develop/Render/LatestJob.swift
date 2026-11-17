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
    /// `isWanted` sees the new value and the one waiting (if any) under the lock, so a value
    /// that is obsolete (work for a photo you've left) or outranked by the waiting one never
    /// replaces it; it is dropped and false is returned.
    public func submit(_ value: Value, if isWanted: (_ new: Value, _ pending: Value?) -> Bool = { _, _ in true }) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isWanted(value, pending) else { return false }
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

/// A value read and written from several threads, such as the photo that is open now, which
/// background work checks so it can skip a photo that was left before its turn came.
public final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    public init(_ value: Value) { stored = value }

    public var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    /// Changes the value in place under the lock, so two threads' changes can't overwrite each other.
    public func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
