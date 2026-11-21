import Foundation

/// The one rule for changing photo in a photo view (Develop and Loupe): the last photo stays on
/// screen exactly as it is, at its zoom and spot, until the next photo has the picture the view
/// should show, and then the new photo, its zoom and its spot go on in one step
/// (`ZoomScrollView.show(_:pixelSize:zoom:holding:)`). Never a softer stand-in first (the grid
/// thumbnail, a stored preview swapped for a render, the last photo blown up to the next one's
/// zoom), which Rosh saw as a flicker or "low resolution first" on every change (Nov 21, 2026).
/// Each photo view decides what "ready" is (`end`); this keeps the state, the time limit and the
/// timing log line, so the views can't drift apart again.
@MainActor
final class PhotoChangeHold: ObservableObject {
    /// The photo view keeps the last photo.
    @Published private(set) var isHolding = false
    /// The longest the last photo stays up; then the view shows what it has.
    let limit: TimeInterval
    /// Called with "<reason> +N ms" when a hold ends, for the view's timing log.
    var log: ((String) -> Void)?

    private var timeout: DispatchWorkItem?
    private var began = Date()

    init(limit: TimeInterval = 1.0) {
        self.limit = limit
    }

    /// The next photo is on its way: keep the last one until `end` (or `limit`).
    func begin() {
        timeout?.cancel()
        isHolding = true
        began = Date()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.end(because: "after waiting the limit") }
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: item)
    }

    /// The next photo is ready (or there is nothing to wait for): show it. `reason` nil ends
    /// quietly (another photo opened before this one was ready).
    func end(because reason: String?) {
        timeout?.cancel()
        timeout = nil
        guard isHolding else { return }
        isHolding = false
        if let reason { log?("\(reason) +\(Int((Date().timeIntervalSince(began) * 1000).rounded())) ms") }
    }
}
