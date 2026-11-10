import AppKit
import SwiftUI

/// Puts the Develop histogram's picture (`HistogramPicture`) on screen from the queue that counts
/// it, without SwiftUI and without the main thread, as `LiveFrameSink` does for the photo
/// (AT-040). Going through SwiftUI, each count waited for the main thread, which a drag keeps
/// busy, and then for an update of the panel around it, so the graph lagged behind the photo and
/// moved in jumps (Rosh, Nov 10, 2026: "sticky, freezy").
///
/// The main thread only says which open photo pictures belong to (`reset`) and which layer shows
/// them (`setTarget`). The lock is never held across a Core Animation commit.
final class HistogramSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var layer: CALayer?
    /// The open photo pictures must belong to (`DevelopController.openGeneration`).
    private var generation = -1
    /// The rank (`DevelopMeasureRequest.rank`) of the picture shown, so an older count never
    /// replaces a newer one.
    private var shownRank = -1
    private var picture: CGImage?

    /// A photo was opened: what is shown is cleared and only pictures of `generation` are taken.
    func reset(generation: Int) {
        lock.lock()
        self.generation = generation
        shownRank = -1
        picture = nil
        let target = layer
        lock.unlock()
        if let target { Self.show(nil, on: target) }
    }

    /// The layer pictures go on; it gets the current picture at once.
    func setTarget(_ layer: CALayer?) {
        lock.lock()
        self.layer = layer
        let picture = self.picture
        lock.unlock()
        if let layer { Self.show(picture, on: layer) }
    }

    /// Shows `picture`, counted for open `generation` at `rank`, on the calling thread, unless a
    /// newer one is already shown or another photo has been opened since.
    func present(_ picture: CGImage, generation: Int, rank: Int) {
        lock.lock()
        guard generation == self.generation, rank >= shownRank else {
            lock.unlock()
            return
        }
        shownRank = rank
        self.picture = picture
        let target = layer
        lock.unlock()
        if let target {
            Self.show(picture, on: target)
            // This thread has no run loop to commit for it.
            CATransaction.flush()
        }
    }

    private static func show(_ picture: CGImage?, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = picture
        CATransaction.commit()
    }
}

/// The view `HistogramSink` draws into. It passes every mouse event through to the SwiftUI
/// histogram around it (hover, drag and double-click on the tone regions).
struct HistogramLayerView: NSViewRepresentable {
    let sink: HistogramSink

    func makeNSView(context: Context) -> PassThroughLayerView {
        let view = PassThroughLayerView()
        view.sink = sink
        sink.setTarget(view.pictureLayer)
        return view
    }

    func updateNSView(_ view: PassThroughLayerView, context: Context) {
        if view.sink !== sink {
            view.sink?.setTarget(nil)
            view.sink = sink
            sink.setTarget(view.pictureLayer)
        }
    }

    static func dismantleNSView(_ view: PassThroughLayerView, coordinator: ()) {
        view.sink?.setTarget(nil)
        view.sink = nil
    }

    final class PassThroughLayerView: NSView {
        let pictureLayer = CALayer()
        weak var sink: HistogramSink?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            pictureLayer.contentsGravity = .resize
            pictureLayer.minificationFilter = .trilinear
            pictureLayer.magnificationFilter = .linear
            pictureLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(pictureLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pictureLayer.frame = bounds
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
