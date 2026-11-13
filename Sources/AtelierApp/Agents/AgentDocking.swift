import AgentMCP
import AppKit
import AtelierCore
import Foundation

/// Atelier's side of the docking protocol (AT-050h): a chat app such as Docent asks for
/// Atelier's window to fill a frame beside its own. Docking is the chat app's window code, never
/// a tool, so no model can move the window. While docked (and afterwards, until there's room
/// again) side panels collapse before the photo does: `ContentView` reads `width` and lays out
/// with `DockLayout`.
@MainActor
final class AgentDock: ObservableObject {
    /// The width the panels are laid out for while docked or still narrow after; nil when
    /// nothing constrains them (both panels as the person left them).
    @Published private(set) var width: Double?
    /// The chat app docked to the window, for Settings and the activity log.
    @Published private(set) var dockedTo: AgentClient?

    private(set) var coordinator: DockingCoordinator!
    private weak var server: AgentServer?
    /// The window's frame before docking, to restore on `docking/undock` with `restore`.
    private var savedFrame: NSRect?
    /// The frame Atelier last put the window at, and whether it is doing so now: any other move
    /// while the person drags the window is theirs, and undocks.
    private var placedFrame: NSRect?
    private var placing = false
    /// Let go but still narrower than both panels need: panels follow the window's width until
    /// they all fit again.
    private var leftover = false
    private var observers: [NSObjectProtocol] = []

    init(server: AgentServer) {
        self.server = server
        coordinator = DockingCoordinator(windows: AtelierDockWindows(dock: self))
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.windowChanged(window) }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowClosing(window) }
        })
    }

    private var window: NSWindow? { server?.model?.mainWindow }

    /// Quitting: the chat app is told before the connection closes.
    func quitting() {
        coordinator.releaseAllNow(reason: .quit)
        dockedTo = nil
    }

    /// Settings > Agents > Undock: as if the person had moved the window away.
    func undockByHand() {
        Task { await coordinator.released(reason: .user) }
    }

    /// ContentView found that both panels fit the window again.
    func panelsFit() {
        guard leftover, dockedTo == nil else { return }
        leftover = false
        width = nil
    }

    // MARK: Requests (from AtelierDockWindows)

    func place(_ request: DockRequest, starting: Bool) async -> DockPlacement {
        guard let window, window.isVisible || window.isMiniaturized else {
            return .unavailable("Atelier's window isn't open. Open it, then dock again.")
        }
        if window.styleMask.contains(.fullScreen) {
            return .unavailable("Atelier's window is in full screen. Leave full screen (⌃⌘F), then dock again.")
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if starting, dockedTo == nil { savedFrame = window.frame }
        let target = NSRect(x: request.frame.x, y: request.frame.y, width: request.frame.width, height: request.frame.height)
        let narrowing = target.width < window.frame.width
        if narrowing {
            // Collapse the panels first, so the window's minimum width drops before it shrinks.
            width = target.width
            await nextLayoutPass(window)
        }
        setFrame(target, of: window)
        if window.frame.width > target.width + 1 {
            // The old panels' minimum width held the window wider: once more after they've gone.
            try? await Task.sleep(for: .milliseconds(50))
            await nextLayoutPass(window)
            setFrame(target, of: window)
        }
        placedFrame = window.frame
        width = window.frame.width
        leftover = false
        if starting {
            // Beside the chat app, without taking the keyboard from it.
            window.orderFrontRegardless()
            if dockedTo?.id != request.client?.id, let client = request.client {
                server?.log(client.name, .call, "Docked Atelier's window beside it")
            }
            dockedTo = request.client
        }
        let frame = window.frame
        return .placed(DockFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
    }

    func release(restore: Bool, reason: DockRelease?) {
        let name = dockedTo?.name
        dockedTo = nil
        placedFrame = nil
        if restore, let savedFrame, let window {
            setFrame(savedFrame, of: window)
            width = nil
            leftover = false
        } else if let window {
            // The window stays where it is; the panels come back as soon as there's room.
            width = window.frame.width
            leftover = true
        }
        savedFrame = nil
        if let name {
            server?.log(name, .call, reason == .user ? "Undocked: Atelier's window was moved" : "Undocked")
        }
    }

    // MARK: Window events

    private func windowChanged(_ changed: NSWindow?) {
        guard let changed, changed === window, !placing else { return }
        if dockedTo != nil {
            // Only the person's own drag or resize undocks; Atelier's own layout passes don't.
            let byHand = changed.inLiveResize || NSEvent.pressedMouseButtons != 0
            guard byHand, let placedFrame, !Self.same(changed.frame, placedFrame) else { return }
            Task { await coordinator.released(reason: .user) }
        } else if leftover {
            width = changed.frame.width
        }
    }

    private func windowClosing(_ closing: NSWindow?) {
        guard let closing, closing === window, dockedTo != nil else { return }
        dockedTo = nil
        placedFrame = nil
        savedFrame = nil
        width = nil
        Task { await coordinator.released(reason: .windowClosed) }
    }

    private func setFrame(_ frame: NSRect, of window: NSWindow) {
        placing = true
        window.setFrame(frame, display: true, animate: false)
        placing = false
    }

    private static func same(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// Lets SwiftUI lay the window out with the new panels before it moves.
    private func nextLayoutPass(_ window: NSWindow) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

/// The protocol's view of Atelier's one window ("front"), from the sessions' threads.
final class AtelierDockWindows: DockingWindows, @unchecked Sendable {
    private weak var dock: AgentDock?

    init(dock: AgentDock) {
        self.dock = dock
    }

    func minimumWidth(of window: String) async -> Double? {
        guard window == DockingProtocol.frontWindow else { return nil }
        return await MainActor.run { dock?.hasWindow == true ? DockLayout.minimumWidth : nil }
    }

    func place(_ request: DockRequest, starting: Bool) async -> DockPlacement {
        guard let dock else { return .unavailable("Atelier is closing.") }
        return await dock.place(request, starting: starting)
    }

    func release(_ window: String, restore: Bool, reason: DockRelease?) async {
        await MainActor.run { dock?.release(restore: restore, reason: reason) }
    }
}

extension AgentDock {
    var hasWindow: Bool { window != nil }
}
