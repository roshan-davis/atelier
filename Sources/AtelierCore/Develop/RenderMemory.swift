import CoreImage
import Darwin
import Foundation

/// Keeps what Develop holds in Core Image's cache within a memory budget (AT-077).
///
/// Develop keeps rendered stages in Core Image's cache (`insertingIntermediate(cache: true)`):
/// step 1, Lens Blur's result, the depth map, the tone stages, the clipping copy. Core Image
/// lets them go only when it decides to, and nothing ever told it to, so every new Lens Blur
/// result (one per slider tick or brush stroke, about 190 MB at full size on a Zf file) stayed
/// in memory with the ones before it. Rosh, Nov 16, 2026: Atelier grew to 16 GB after some Lens
/// Blur work and the 48 GB Mac froze. Atelier must run on any Apple Silicon Mac, 8 GB included,
/// without hogging memory.
///
/// Every stage kept for later goes through `kept(_:)`, which counts its pixels. When the stages
/// kept since the last clear pass the budget, the cache is cleared first, so it never holds more
/// than about the budget. It is also cleared when a photo or the Lens Blur mode closes, when the
/// view goes back to Fit (`DevelopController`), and when macOS says memory is getting low; the
/// AI models (`OnnxHost`) are unloaded then too, and after 30 s without a run.
/// Clearing costs one slower frame (step 1 is decoded again), never a wrong one.
public final class RenderMemory: @unchecked Sendable {
    public static let shared = RenderMemory(context: DevelopRenderer.shared.context,
                                            budget: budget(physicalMemory: ProcessInfo.processInfo.physicalMemory))

    /// Posted (on the main queue) when macOS reports memory pressure, after the cache is
    /// cleared, so the app can drop what it keeps itself (full-size images, decoded previews).
    public static let pressure = Notification.Name("AtelierRenderMemoryPressure")

    /// Bytes of kept stages allowed before the cache is cleared: a sixteenth of the Mac's memory,
    /// at least 768 MB and at most 2 GB (8 GB Mac: 768 MB; 16 GB: 1 GB; 48 GB: 2 GB). A full-size
    /// stage of a 24 MP photo is about 190 MB, so 768 MB still holds step 1, the depth map and
    /// the last Lens Blur results. It was a tenth, up to 4 GB, until the Mac check of PR #157
    /// (Nov 16, 2026): 21 Lens Blur Amount edits at full size took Atelier from 2.5 to 6.3 GB.
    public static func budget(physicalMemory: UInt64) -> Int {
        let sixteenth = Double(physicalMemory) / 16
        return Int(min(2 * 1_073_741_824, max(768 * 1_048_576, sixteenth)))
    }

    /// A stage's estimated size in the cache: its pixels in the working format (half-float
    /// RGBA, 8 bytes each). Infinite or empty extents count as nothing.
    public static func estimatedBytes(of image: CIImage) -> Int {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0,
              extent.width < 1e6, extent.height < 1e6 else { return 0 }
        return Int(extent.width.rounded(.up) * extent.height.rounded(.up)) * 8
    }

    public let budget: Int
    private let context: CIContext
    private let lock = NSLock()
    private var keptBytes = 0
    private var clearCount = 0
    private var lastReason: String?
    private var pressureSource: DispatchSourceMemoryPressure?

    public init(context: CIContext, budget: Int) {
        self.context = context
        self.budget = budget
    }

    /// `image`, kept in Core Image's cache once rendered, within the budget.
    public func kept(_ image: CIImage) -> CIImage {
        let bytes = Self.estimatedBytes(of: image)
        let over: Bool = lock.withLock {
            let over = keptBytes > 0 && keptBytes + bytes > budget
            keptBytes = over ? bytes : keptBytes + bytes
            return over
        }
        if over { clearCaches(because: "over the budget") }
        return image.insertingIntermediate(cache: true)
    }

    /// Lets go of everything Core Image keeps for Develop. Safe from any thread (Core Image
    /// contexts are thread-safe); a render running now finishes with what it has.
    public func clear(because reason: String) {
        lock.withLock { keptBytes = 0 }
        clearCaches(because: reason)
    }

    /// `clear(because:)`, and unloads the AI models too (`OnnxHost.unloadAll`): for a memory
    /// warning, and when a photo or Lens Blur closes. Waits for a model run in progress, so call
    /// it off the main thread.
    public func releaseAll(because reason: String) {
        clear(because: reason)
        OnnxHost.unloadAll()
    }

    /// `releaseAll(because:)` on a background queue, for the main thread.
    public func releaseAllSoon(because reason: String) {
        DispatchQueue.global(qos: .utility).async { self.releaseAll(because: reason) }
    }

    private func clearCaches(because reason: String) {
        context.clearCaches()
        lock.withLock {
            clearCount += 1
            lastReason = reason
        }
    }

    /// Stages counted since the last clear, how many clears so far and why the last one ran (tests,
    /// `DevelopTimingLog`).
    public var status: (keptBytes: Int, clears: Int, lastReason: String?) {
        lock.withLock { (keptBytes, clearCount, lastReason) }
    }

    /// Starts listening for macOS's memory warnings: on each one the cache is cleared, the AI
    /// models are unloaded and `pressure` is posted. Call once at launch.
    public func watchMemoryPressure() {
        lock.withLock {
            guard pressureSource == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                                 queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                self?.releaseAll(because: "memory pressure")
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.pressure, object: nil) }
            }
            source.resume()
            pressureSource = source
        }
    }

    /// This process's memory as Activity Monitor's Memory column shows it (`phys_footprint`),
    /// in bytes; nil if the kernel won't say.
    public static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
