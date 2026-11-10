import AppKit
import os
import QuartzCore
import SwiftUI

/// Optional instrumentation for a slider drag in the single-photo Develop view. The display
/// link is a presentation estimate. Core Animation does not report when these layers scan out.
@MainActor
final class DevelopFrameHUD {
    static let preference = "develop.frameHUD"

    private struct Submission {
        let render: PhotoFeed.RenderTiming
        let time: CFTimeInterval
    }

    private struct Drag {
        let name: String
        let startingValue: Double?
        let firstPossibleCount: Int
        var firstChange: CFTimeInterval?
        var firstFrame: CFTimeInterval?
        var firstRender: CFTimeInterval?
        var lastFrame: CFTimeInterval?
        var longestGap: CFTimeInterval?
        var ticks = 0
        var frames = 0
        var busy = Sample()
        /// Main passes longer than one display refresh: each one held back at least one frame.
        var longPasses = 0
        /// Histogram and color scope updates published by `DevelopController` (each one updates
        /// every view observing it, like a settings change).
        var histogramUpdates = 0
        var fallbacks = Fallbacks()
    }

    private struct Sample {
        var count = 0
        var total = 0.0
        var maximum = 0.0

        mutating func record(_ seconds: CFTimeInterval) {
            count += 1
            total += seconds
            maximum = max(maximum, seconds)
        }

        var meanMS: String { count == 0 ? "—" : String(format: "%.1f", 1_000 * total / Double(count)) }
        var maxMS: String { count == 0 ? "—" : String(format: "%.1f", 1_000 * maximum) }
    }

    private struct Fallbacks {
        var liveOff = 0
        var poolFull = 0

        mutating func record(_ reason: PhotoFeed.Fallback) {
            switch reason {
            case .liveFramesOff: liveOff += 1
            case .poolFull: poolFull += 1
            }
        }

        var detail: String { "\(liveOff + poolFull) (live off \(liveOff), pool full \(poolFull))" }
    }

    private(set) var active = false
    private var drag: Drag?
    private var finished: [String] = []
    private var finishingDrag: Drag?
    private var passStart: CFTimeInterval?
    /// Each measured main pass is also an Instruments interval ("Main pass" in Points of
    /// Interest), so a trace can line long passes up with SwiftUI's and Time Profiler's tracks.
    private var passInterval: OSSignpostIntervalState?
    private static let signposter = OSSignposter(subsystem: "Atelier", category: .pointsOfInterest)
    /// The display's refresh period, from the display link (120 Hz until it reports).
    private var refreshPeriod: CFTimeInterval = 1.0 / 120
    private var busy = Sample()
    private var fallbacks = Fallbacks()
    private var lastCompletedDrag: Drag?
    private var pending: Submission?
    private var lastScheduledCount = 0
    private var lastCount: Int?
    private var intervalStart: CFTimeInterval?
    private var tick = Sample()
    private var render = Sample()
    private var ready = Sample()
    private var handoff = Sample()
    private var wait = Sample()
    private var refresh = Sample()

    func setActive(_ active: Bool) {
        self.active = active
        drag = nil
        finishingDrag = nil
        passStart = nil
        if let passInterval { Self.signposter.endInterval("Main pass", passInterval) }
        passInterval = nil
        pending = nil
        lastCount = nil
        lastCompletedDrag = nil
        finished.removeAll()
        intervalStart = nil
        resetSamples()
    }

    func begin(_ name: String, value: Double? = nil) {
        guard active, drag?.name != name else { return }
        end()
        if intervalStart == nil { intervalStart = CACurrentMediaTime() }
        drag = Drag(name: name, startingValue: value, firstPossibleCount: lastScheduledCount + 1)
    }

    func recordTick(from start: CFTimeInterval, changed: Bool) {
        guard active, drag != nil else { return }
        tick.record(CACurrentMediaTime() - start)
        if changed {
            drag?.ticks += 1
            if drag?.firstChange == nil { drag?.firstChange = start }
        }
    }

    /// Point and wheel callbacks use the same clock and render serial as slider callbacks.
    func measure(_ name: String, startingValue: @autoclosure () -> Double? = nil, _ edit: () -> Void) {
        guard active else { edit(); return }
        let start = CACurrentMediaTime()
        if drag?.name != name { begin(name, value: startingValue()) }
        let count = lastScheduledCount
        edit()
        recordTick(from: start, changed: count != lastScheduledCount)
    }

    func end(_ name: String? = nil) {
        guard let drag, name == nil || drag.name == name else { return }
        self.drag = nil
        pending = nil
        if passStart != nil {
            finishingDrag = drag
        } else {
            finish(drag)
        }
    }

    func afterWaiting() {
        passStart = CACurrentMediaTime()
        if passInterval == nil, drag != nil {
            passInterval = Self.signposter.beginInterval("Main pass", id: Self.signposter.makeSignpostID())
        }
    }

    func beforeWaiting() {
        if let passStart, drag != nil || finishingDrag != nil {
            let duration = CACurrentMediaTime() - passStart
            busy.record(duration)
            drag?.busy.record(duration)
            finishingDrag?.busy.record(duration)
            if duration > refreshPeriod {
                drag?.longPasses += 1
                finishingDrag?.longPasses += 1
            }
        }
        if let passInterval { Self.signposter.endInterval("Main pass", passInterval) }
        passInterval = nil
        passStart = nil
        if let finishingDrag {
            finish(finishingDrag)
            self.finishingDrag = nil
        }
    }

    private func finish(_ drag: Drag) {
        guard drag.ticks > 0 else { return }
        lastCompletedDrag = drag
        let first = drag.firstFrame.flatMap { frame in drag.firstChange.map { frame - $0 } }
        let startingValue = drag.startingValue.map { String($0) } ?? "—"
        var line = "\(drag.name) start=\(startingValue) changed=\(drag.ticks) frames=\(drag.frames)"
        line += " first=\(Self.ms(first)) ms firstRender=\(Self.ms(drag.firstRender)) ms longest=\(Self.ms(drag.longestGap)) ms"
        line += " main pass \(drag.busy.meanMS)/\(drag.busy.maxMS) ms (\(drag.busy.count) passes,"
        line += " \(drag.longPasses) over one refresh) histogram updates \(drag.histogramUpdates)"
        line += " CG fallbacks \(drag.fallbacks.detail)"
        finished.append(line)
    }

    func scheduled(_ count: Int) { lastScheduledCount = count }

    /// `DevelopController` published a new histogram or color scope during a drag.
    func histogramPublished() {
        guard active, drag?.firstChange != nil else { return }
        drag?.histogramUpdates += 1
    }

    func fallback(_ reason: PhotoFeed.Fallback, count: Int) {
        guard let drag, drag.firstChange != nil, count >= drag.firstPossibleCount else { return }
        fallbacks.record(reason)
        self.drag?.fallbacks.record(reason)
    }

    func submit(_ render: PhotoFeed.RenderTiming) {
        guard active, let drag, drag.firstChange != nil, render.count >= drag.firstPossibleCount,
              render.count > (lastCount ?? -1) else { return }
        // A live frame reaches the layer on the render queue (`LiveFrameSink`); an ordinary image
        // on the main thread, now.
        pending = Submission(render: render, time: render.shownAt ?? CACurrentMediaTime())
    }

    func display(_ link: CADisplayLink, assetID: Int64?) -> String? {
        if let submission = pending, var drag, link.timestamp >= submission.time {
            pending = nil
            lastCount = submission.render.count
            render.record(submission.render.duration)
            ready.record(max(0, link.timestamp - submission.render.readyAt))
            wait.record(submission.render.queueWait)
            handoff.record(submission.time - submission.render.readyAt)
            if let last = drag.lastFrame {
                drag.longestGap = max(drag.longestGap ?? 0, link.timestamp - last)
            }
            drag.lastFrame = link.timestamp
            if drag.firstFrame == nil {
                drag.firstFrame = link.timestamp
                drag.firstRender = submission.render.duration
            }
            drag.frames += 1
            self.drag = drag
        }

        guard let start = intervalStart else { return nil }
        let period = link.targetTimestamp - link.timestamp
        if period > 0 {
            refresh.record(period)
            refreshPeriod = period
        }
        let now = CACurrentMediaTime()
        guard now - start >= 1 else { return nil }
        let fps = Double(render.count) / (now - start)
        let hz = refresh.total > 0 ? Double(refresh.count) / refresh.total : 0
        let rate = String(format: "%.0f fps / %.0f Hz", fps, hz)
        let shownDrag = drag ?? lastCompletedDrag
        let gap = Self.ms(shownDrag?.longestGap)
        let shownBusy = shownDrag?.busy ?? busy
        let shownFallbacks = shownDrag?.fallbacks ?? fallbacks
        let line = "Frame HUD \(rate), main tick \(tick.meanMS)/\(tick.maxMS) ms, render \(render.meanMS)/\(render.maxMS) ms"
            + ", queue \(wait.meanMS)/\(wait.maxMS) ms, ready to layer \(handoff.meanMS)/\(handoff.maxMS) ms"
            + ", ready to refresh \(ready.meanMS)/\(ready.maxMS) ms, drag gap \(gap) ms"
        DevelopTimingLog.shared.log(assetID, line + ", main pass \(busy.meanMS)/\(busy.maxMS) ms (\(busy.count) passes)"
                                    + ", CG fallbacks \(fallbacks.detail)" + finished.map { " | drag \($0)" }.joined())
        let summary = "\(rate)  ·  estimated display\nMain tick       \(tick.meanMS) ms"
            + "\nMain pass       \(shownBusy.meanMS)/\(shownBusy.maxMS) ms"
            + "\nRender          \(render.meanMS) ms\nReady → refresh \(ready.meanMS) ms\nLongest gap     \(gap) ms"
            + "\nCG fallbacks    \(shownFallbacks.liveOff + shownFallbacks.poolFull)"
        finished.removeAll(keepingCapacity: true)
        resetSamples()
        intervalStart = drag == nil ? nil : now
        return summary
    }

    private func resetSamples() {
        tick = Sample()
        render = Sample()
        ready = Sample()
        handoff = Sample()
        wait = Sample()
        refresh = Sample()
        busy = Sample()
        fallbacks = Fallbacks()
    }

    private static func ms(_ seconds: CFTimeInterval?) -> String {
        seconds.map { String(format: "%.1f", 1_000 * $0) } ?? "—"
    }
}

// A hand-written key instead of SwiftUI's @Entry macro: the macro's plugin ships only
// with Xcode, so `swift build` with the Command Line Tools toolchain can't expand it.
private struct DevelopFrameHUDKey: EnvironmentKey {
    static var defaultValue: DevelopFrameHUD? { nil }
}

extension EnvironmentValues {
    var developFrameHUD: DevelopFrameHUD? {
        get { self[DevelopFrameHUDKey.self] }
        set { self[DevelopFrameHUDKey.self] = newValue }
    }
}

struct DevelopFrameHUDOverlay: NSViewRepresentable {
    let hud: DevelopFrameHUD
    let assetID: Int64?

    func makeNSView(context: Context) -> DisplayView { DisplayView(hud: hud) }
    func updateNSView(_ view: DisplayView, context: Context) { view.assetID = assetID }
    static func dismantleNSView(_ view: DisplayView, coordinator: ()) { view.stop() }

    final class DisplayView: NSView {
        let hud: DevelopFrameHUD
        var assetID: Int64?
        private var link: CADisplayLink?
        private var observers: [CFRunLoopObserver] = []
        private let label = NSTextField(wrappingLabelWithString: "Frame diagnostics\nDrag a slider, curve point or wheel")
        private static let highRefresh = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

        init(hud: DevelopFrameHUD) {
            self.hud = hud
            super.init(frame: .zero)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.setAccessibilityIdentifier("develop-frame-diagnostics")
            label.setAccessibilityLabel("Develop frame diagnostics")
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 9)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            let link = displayLink(target: self, selector: #selector(refresh(_:)))
            link.preferredFrameRateRange = Self.highRefresh
            link.add(to: .main, forMode: .common)
            self.link = link
            hud.setActive(true)
            // Start early and stop late to bracket the work in the pass, including deferred UI work.
            observe(.afterWaiting, order: CFIndex.min) { $0.afterWaiting() }
            observe(.beforeWaiting, order: CFIndex.max) { $0.beforeWaiting() }
        }

        private func observe(_ activity: CFRunLoopActivity, order: CFIndex, record: @escaping (DevelopFrameHUD) -> Void) {
            guard let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, order, { [weak hud] _, _ in
                MainActor.assumeIsolated { if let hud { record(hud) } }
            }) else { return }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }

        func stop() {
            observers.forEach { CFRunLoopObserverInvalidate($0) }
            observers.removeAll()
            link?.invalidate()
            link = nil
            hud.setActive(false)
        }

        @objc private func refresh(_ link: CADisplayLink) {
            if let summary = hud.display(link, assetID: assetID) { label.stringValue = summary }
        }
    }
}
