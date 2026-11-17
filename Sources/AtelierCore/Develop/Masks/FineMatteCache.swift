import CoreGraphics
import Foundation

/// Fine Edges' mattes for the whole app, shared by every `DevelopSession` of a photo: the editor's
/// proxy, its full-size render and the Lens Blur photo's Save all see the same matte, so Save
/// doesn't run the model again (Mac check of PR #153, Nov 16, 2026: Save with a Select Subject
/// area took 70.6 s, running Fine Edges again after the editor had just found the same matte).
///
/// A matte is the model's square of values (resolution-free), keyed by the file, its lens
/// geometry, the model and the square on the photo's 1/256 grid, so a proxy and a full-size
/// session of the same photo find each other's. The last few are kept. A matte being found is
/// never found twice at once: whoever asks next waits for it (`matte(for:find:)`) or renders
/// without it for now (`cached(_:)`, `startIfIdle(_:find:)`).
public final class FineMatteCache: @unchecked Sendable {
    public static let shared = FineMatteCache()

    public struct Key: Hashable, Sendable {
        /// The photo's file.
        public var file: String
        /// The photo's lens geometry (`DevelopSettings.lensGeometryKey`).
        public var geometry: DevelopSettings
        public var model: FineEdges.Model
        /// The square, in 1/256ths of the photo's long side, and the grid's size.
        public var x, y, width, height, gridWidth, gridHeight: Int

        public init(file: String, geometry: DevelopSettings, model: FineEdges.Model,
                    x: Int, y: Int, width: Int, height: Int, gridWidth: Int, gridHeight: Int) {
            self.file = file
            self.geometry = geometry
            self.model = model
            self.x = x; self.y = y; self.width = width; self.height = height
            self.gridWidth = gridWidth; self.gridHeight = gridHeight
        }
    }

    /// What a lookup found: a matte (nil inside when the model failed), one still being found,
    /// or nothing yet.
    public enum Lookup: Equatable {
        case found([Float]?)
        case pending
        case missing
    }

    private let condition = NSCondition()
    private var entries: [(key: Key, matte: [Float]?)] = []
    private var pending: Set<Key> = []
    let limit: Int

    init(limit: Int = 6) { self.limit = limit }

    public func lookup(_ key: Key) -> Lookup {
        condition.lock()
        defer { condition.unlock() }
        if let entry = entries.first(where: { $0.key == key }) { return .found(entry.matte) }
        return pending.contains(key) ? .pending : .missing
    }

    /// Starts finding `key`'s matte in the background unless it is known or being found;
    /// `done` runs once it is in (on the finding thread). Returns whether it started.
    @discardableResult
    public func startIfIdle(_ key: Key, find: @escaping @Sendable () -> [Float]?, done: @escaping @Sendable () -> Void) -> Bool {
        condition.lock()
        guard !pending.contains(key), !entries.contains(where: { $0.key == key }) else {
            condition.unlock()
            return false
        }
        pending.insert(key)
        condition.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.finish(key, find())
            done()
        }
        return true
    }

    /// `key`'s matte, waiting for it if it is being found, finding it here if nobody is (for
    /// Save and export, which wait).
    public func matte(for key: Key, find: () -> [Float]?) -> [Float]? {
        condition.lock()
        while true {
            if let entry = entries.first(where: { $0.key == key }) {
                condition.unlock()
                return entry.matte
            }
            if !pending.contains(key) { break }
            condition.wait()
        }
        pending.insert(key)
        condition.unlock()
        let matte = find()
        finish(key, matte)
        return matte
    }

    private func finish(_ key: Key, _ matte: [Float]?) {
        condition.lock()
        pending.remove(key)
        entries.removeAll { $0.key == key }
        entries.append((key, matte))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        condition.broadcast()
        condition.unlock()
    }

    /// Forgets every matte (a model was downloaded or removed).
    public func removeAll() {
        condition.lock()
        entries.removeAll()
        condition.unlock()
    }
}

/// Select Subject's and Select Object's Vision masks for the whole app, shared by every
/// `DevelopSession` of a photo like `FineMatteCache`: Vision found a different subject on the
/// full-size photo than on the editor's proxy (Mac check of PR #153), so Save's Fine Edges square
/// differed from the editor's and its matte was found again, and Save didn't match what was
/// shown. Vision's mask is resolution-free (it sees about 1024 pixels either way). The last few
/// are kept; a nil mask (Vision found nothing) is kept too.
public final class SubjectMaskCache: @unchecked Sendable {
    public static let shared = SubjectMaskCache()

    public struct Key: Hashable, Sendable {
        public var file: String
        public var geometry: DevelopSettings
        public var box: DevelopSettings.MaskRect?

        public init(file: String, geometry: DevelopSettings, box: DevelopSettings.MaskRect?) {
            self.file = file
            self.geometry = geometry
            self.box = box
        }
    }

    private let lock = NSLock()
    private var entries: [(key: Key, mask: CGImage?)] = []
    let limit: Int

    init(limit: Int = 8) { self.limit = limit }

    /// The mask found for `key`: `.some(nil)` when Vision found nothing, nil when not known.
    public func lookup(_ key: Key) -> CGImage?? {
        lock.withLock { entries.first(where: { $0.key == key }).map { $0.mask } }
    }

    public func store(_ key: Key, _ mask: CGImage?) {
        lock.withLock {
            entries.removeAll { $0.key == key }
            entries.append((key, mask))
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
        }
    }
}
