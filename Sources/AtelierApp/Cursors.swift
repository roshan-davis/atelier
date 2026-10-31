import AppKit
import SwiftUI

/// Every pointer shape Lightfast shows, named by what a click or drag there does. Views never set
/// an `NSCursor` themselves: they say which shape a spot has (`.cursor(_:)` in SwiftUI,
/// `Cursors.shared` in AppKit) and `Cursors` shows it, keeps it through a drag and puts the
/// arrow back when the view goes away.
enum CursorShape: Equatable {
    case arrow
    /// A click there selects or jumps to something.
    case link
    /// A drag moves this (the photo when zoomed in, a pin, a handle).
    case grab
    /// Moving it now.
    case grabbing
    /// A drag draws or paints.
    case crosshair
    /// A click picks a color.
    case eyedropper
    /// A double-click zooms in.
    case zoomIn
    case zoomOut
    /// A drag rotates (outside the crop frame, a mask's rotate knob).
    case rotate
    /// A drag resizes a frame from this edge or corner.
    case resize(NSCursor.FrameResizePosition)
    /// A divider dragged left and right.
    case columnResize
    /// A divider dragged up and down.
    case rowResize
    case notAllowed

    /// The shape held while a drag that started on this one goes on.
    var whileDragging: CursorShape { self == .grab ? .grabbing : self }

    @MainActor var nsCursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .link: return .pointingHand
        case .grab: return .openHand
        case .grabbing: return .closedHand
        case .crosshair: return .crosshair
        case .eyedropper: return CustomCursors.eyedropper
        case .zoomIn: return .zoomIn
        case .zoomOut: return .zoomOut
        case .rotate: return CustomCursors.rotate
        case .resize(let position): return .frameResize(position: position, directions: .all)
        case .columnResize: return .columnResize
        case .rowResize: return .rowResize
        case .notAllowed: return .operationNotAllowed
        }
    }
}

/// Shows the cursor for whatever is under the pointer. Each view that has a cursor claims it
/// while the pointer is over it; the one on top wins (a tool over the photo beats the photo,
/// then the latest one entered). A press holds its shape until the mouse goes up, even off the
/// view, so a resize or rotate never drops back to the arrow mid-drag. AppKit and SwiftUI
/// reset the cursor on their own events, so after every mouse and key event the claimed shape
/// is shown again, and a key like Space or ⌘⌥ changes it without moving the mouse.
@MainActor
final class Cursors {
    static let shared = Cursors()

    /// Which claim wins where views overlap.
    enum Layer: Int {
        /// The photo view underneath the tools.
        case photo
        /// Tools, dividers and controls.
        case tool
    }

    private struct Claim {
        var layer: Layer
        var order: Int
        weak var window: NSWindow?
        /// The shape now; asked again whenever something may have changed it. nil passes the
        /// spot to the claim underneath.
        var shape: () -> CursorShape?
    }

    private struct Press {
        var owner: ObjectIdentifier
        var shape: CursorShape
        weak var window: NSWindow?
    }

    private var claims: [ObjectIdentifier: Claim] = [:]
    private var press: Press?
    private var counter = 0
    private var monitor: Any?
    /// Set while a claimed shape is on screen, so the arrow comes back once when the last
    /// claim lets go, and never otherwise.
    private var showing = false

    /// The pointer is over `owner`, which shows `shape`.
    func hover(_ owner: AnyObject, layer: Layer = .tool, window: NSWindow?, shape: @escaping () -> CursorShape?) {
        install()
        let id = ObjectIdentifier(owner)
        let order: Int
        if let existing = claims[id] {
            order = existing.order
        } else {
            counter += 1
            order = counter
        }
        claims[id] = Claim(layer: layer, order: order, window: window, shape: shape)
        apply()
    }

    /// The pointer left `owner`.
    func leave(_ owner: AnyObject) {
        guard claims.removeValue(forKey: ObjectIdentifier(owner)) != nil else { return }
        apply()
    }

    /// A drag started on `owner`: hold `shape` until it ends. Later calls during the same drag
    /// are ignored.
    func press(_ owner: AnyObject, shape: CursorShape, window: NSWindow?) {
        install()
        let id = ObjectIdentifier(owner)
        guard press?.owner != id else { return }
        press = Press(owner: id, shape: shape, window: window)
        apply()
    }

    func release(_ owner: AnyObject) {
        guard press?.owner == ObjectIdentifier(owner) else { return }
        press = nil
        apply()
    }

    /// `owner` went away: drop its claim and any drag it holds.
    func remove(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        claims.removeValue(forKey: id)
        if press?.owner == id { press = nil }
        apply()
    }

    /// Something a claim's shape depends on changed (zoom, a tool, a mode): show it again.
    func refresh() { apply() }

    private var current: (shape: CursorShape, window: NSWindow?)? {
        if let press { return (press.shape, press.window) }
        var best: (claim: Claim, shape: CursorShape)?
        for claim in claims.values {
            guard let shape = claim.shape() else { continue }
            if let top = best, (top.claim.layer.rawValue, top.claim.order) > (claim.layer.rawValue, claim.order) { continue }
            best = (claim, shape)
        }
        return best.map { ($0.shape, $0.claim.window) }
    }

    private func apply() {
        guard let current = self.current else {
            if showing {
                showing = false
                NSCursor.arrow.set()
            }
            return
        }
        // Not over a window in the background or under a sheet.
        if let window = current.window, !window.isKeyWindow || window.attachedSheet != nil { return }
        current.shape.nsCursor.set()
        showing = true
    }

    private func install() {
        guard monitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.mouseMoved, .cursorUpdate, .leftMouseDown, .leftMouseUp, .rightMouseUp,
                                            .flagsChanged, .keyDown, .keyUp, .scrollWheel, .magnify]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            let mouseUp = event.type == .leftMouseUp
            // After the event has been handled, so this comes last.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A drag whose view missed its end (a gesture cut short) lets go here.
                    if mouseUp { self.press = nil }
                    if self.showing || self.current != nil { self.apply() }
                }
            }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.showing else { return }
                self.showing = false
                NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    /// The cursor over this view. Put it after the view's own `.gesture`, so the drag it
    /// watches runs alongside that gesture instead of taking its place.
    func cursor(_ shape: CursorShape) -> some View {
        modifier(CursorModifier(shape: { _ in shape }, whileDragging: nil))
    }

    /// The cursor by where the pointer is over this view (in its own coordinates): what a click
    /// or drag starting there would do. Tools work it out with the same hit test their drag
    /// uses, so the cursor always matches what happens. A drag that starts here keeps its
    /// shape (an open hand closes) until the mouse goes up, unless `whileDragging` says
    /// otherwise.
    func cursor(whileDragging: CursorShape? = nil, _ shape: @escaping (CGPoint) -> CursorShape) -> some View {
        modifier(CursorModifier(shape: shape, whileDragging: whileDragging))
    }
}

/// Identity for a view's claim in `Cursors`.
private final class CursorOwner {}

private struct CursorModifier: ViewModifier {
    let shape: (CGPoint) -> CursorShape
    let whileDragging: CursorShape?
    @State private var owner = CursorOwner()

    func body(content: Content) -> some View {
        content
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let shape = self.shape
                    Cursors.shared.hover(owner, window: Self.eventWindow) { shape(point) }
                case .ended:
                    Cursors.shared.leave(owner)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in
                    Cursors.shared.press(owner, shape: whileDragging ?? shape(drag.startLocation).whileDragging,
                                         window: Self.eventWindow)
                }
                .onEnded { _ in Cursors.shared.release(owner) })
            .onDisappear { Cursors.shared.remove(owner) }
    }

    @MainActor private static var eventWindow: NSWindow? { NSApp.currentEvent?.window ?? NSApp.keyWindow }
}

/// Cursors macOS doesn't have, drawn white with a dark outline like the system's.
@MainActor
private enum CustomCursors {
    /// Lightroom's and Photoshop's eyedropper; the tip is the hot spot.
    static let eyedropper: NSCursor = {
        let size = NSSize(width: 22, height: 22)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let black = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?
                .withSymbolConfiguration(config.applying(.init(paletteColors: [.black]))),
              let white = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?
                .withSymbolConfiguration(config.applying(.init(paletteColors: [.white])))
        else { return .crosshair }
        let image = NSImage(size: size, flipped: false) { bounds in
            let symbol = NSRect(x: (bounds.width - black.size.width) / 2, y: (bounds.height - black.size.height) / 2,
                                width: black.size.width, height: black.size.height)
            for dx in [-1.0, 0, 1] {
                for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                    black.draw(in: symbol.offsetBy(dx: dx, dy: dy))
                }
            }
            white.draw(in: symbol)
            return true
        }
        // The symbol's tip is at its bottom left; hot spots count from the top left.
        let tipX = (size.width - black.size.width) / 2 + 1
        let tipY = (size.height + black.size.height) / 2 - 1
        return NSCursor(image: image, hotSpot: NSPoint(x: tipX, y: tipY))
    }()

    /// A curved two-headed arrow, as outside Lightroom's crop frame.
    static let rotate: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: true) { _ in
            let center = NSPoint(x: 12, y: 13), radius: CGFloat = 7
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 200, endAngle: 340)
            let heads = NSBezierPath()
            for angle in [200.0, 340.0] {
                let radians = angle * .pi / 180
                let tip = NSPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
                // Square to the radius, pointing on along the arc.
                let along = angle < 270 ? -1.0 : 1.0
                let tangent = NSPoint(x: -sin(radians) * along, y: cos(radians) * along)
                let normal = NSPoint(x: cos(radians), y: sin(radians))
                heads.move(to: NSPoint(x: tip.x + tangent.x * 4, y: tip.y + tangent.y * 4))
                heads.line(to: NSPoint(x: tip.x + normal.x * 3.5, y: tip.y + normal.y * 3.5))
                heads.line(to: NSPoint(x: tip.x - normal.x * 3.5, y: tip.y - normal.y * 3.5))
                heads.close()
            }
            NSColor.black.setStroke()
            arc.lineWidth = 4
            arc.stroke()
            heads.lineWidth = 2.5
            heads.lineJoinStyle = .round
            heads.stroke()
            NSColor.white.setStroke()
            NSColor.white.setFill()
            arc.lineWidth = 1.75
            arc.stroke()
            heads.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
}
