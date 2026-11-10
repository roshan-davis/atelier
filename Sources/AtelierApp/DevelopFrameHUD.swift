import AppKit
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
        let startingValue: Double
        let firstPossibleCount: Int
        var firstChange: CFTimeInterval?
        var firstFrame: CFTimeInterval?
        var firstRender: CFTimeInterval?
        var lastFrame: CFTimeInterval?
        var longestGap: CFTimeInterval?
        var ticks = 0
        var frames = 0
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

    private(set) var active = false
    private var drag: Drag?
    private var finished: [String] = []
    private var lastCompletedGap: CFTimeInterval?
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
        pending = nil
        lastCount = nil
        lastCompletedGap = nil
        finished.removeAll()
        intervalStart = nil
        resetSamples()
    }

    func begin(_ name: String, value: Double) {
        guard active else { return }
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

    func end() {
        guard let drag else { return }
        self.drag = nil
        pending = nil
        guard drag.ticks > 0 else { return }
        lastCompletedGap = drag.longestGap
        let first = drag.firstFrame.flatMap { frame in drag.firstChange.map { frame - $0 } }
        finished.append("\(drag.name) start=\(drag.startingValue) changed=\(drag.ticks) frames=\(drag.frames)"
                        + " first=\(Self.ms(first)) ms firstRender=\(Self.ms(drag.firstRender)) ms longest=\(Self.ms(drag.longestGap)) ms")
    }

    func scheduled(_ count: Int) { lastScheduledCount = count }

    func submit(_ render: PhotoFeed.RenderTiming) {
        guard active, let drag, drag.firstChange != nil, render.count >= drag.firstPossibleCount,
              render.count > (lastCount ?? -1) else { return }
        pending = Submission(render: render, time: CACurrentMediaTime())
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
        if period > 0 { refresh.record(period) }
        let now = CACurrentMediaTime()
        guard now - start >= 1 else { return nil }
        let fps = Double(render.count) / (now - start)
        let hz = refresh.total > 0 ? Double(refresh.count) / refresh.total : 0
        let rate = String(format: "%.0f fps / %.0f Hz", fps, hz)
        let gap = Self.ms(drag == nil ? lastCompletedGap : drag?.longestGap)
        let line = "Frame HUD \(rate), main tick \(tick.meanMS)/\(tick.maxMS) ms, render \(render.meanMS)/\(render.maxMS) ms"
            + ", queue \(wait.meanMS)/\(wait.maxMS) ms, ready to layer \(handoff.meanMS)/\(handoff.maxMS) ms"
            + ", ready to refresh \(ready.meanMS)/\(ready.maxMS) ms, drag gap \(gap) ms"
        DevelopTimingLog.shared.log(assetID, line + finished.map { " | drag \($0)" }.joined())
        let summary = "\(rate)  ·  estimated display\nMain tick      \(tick.meanMS) ms\nRender         \(render.meanMS) ms\nReady → refresh \(ready.meanMS) ms\nLongest gap    \(gap) ms"
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
    }

    private static func ms(_ seconds: CFTimeInterval?) -> String {
        seconds.map { String(format: "%.1f", 1_000 * $0) } ?? "—"
    }
}

extension EnvironmentValues {
    @Entry var developFrameHUD: DevelopFrameHUD?
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
        private let label = NSTextField(wrappingLabelWithString: "Frame diagnostics\nDrag a Develop slider")
        private static let highRefresh = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

        init(hud: DevelopFrameHUD) {
            self.hud = hud
            super.init(frame: .zero)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
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
        }

        func stop() {
            link?.invalidate()
            link = nil
            hud.setActive(false)
        }

        @objc private func refresh(_ link: CADisplayLink) {
            if let summary = hud.display(link, assetID: assetID) { label.stringValue = summary }
        }
    }
}
