import AgentActions
import Foundation

// The docking protocol (AT-050h): a chat app (Docent) asks the app to place its window beside
// the chat's, over the MCP connection it already has. These are JSON-RPC methods outside
// `tools/list`, so no model ever sees or calls them; only the chat app's own window code sends
// them. The reference is Docs/Atelier-Agent-Actions.md, "Docking beside a chat app".

/// A window frame in points, in AppKit's global screen coordinates: the origin is the bottom-left
/// corner of the main screen and y grows upward, as `NSWindow.frame` reads. Both sides can pass
/// a window's frame through without converting it.
public struct DockFrame: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var json: JSONValue {
        .object(["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)])
    }

    /// Reads `{"x":…, "y":…, "width":…, "height":…}`; width and height must be above zero.
    public init?(json: JSONValue?) {
        guard let x = json?["x"]?.doubleValue, let y = json?["y"]?.doubleValue,
              let width = json?["width"]?.doubleValue, let height = json?["height"]?.doubleValue,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        self.init(x: x, y: y, width: width, height: height)
    }
}

/// One `docking/dock` or `docking/update`: the frame to fill and the window that fills it.
public struct DockRequest: Sendable, Hashable {
    /// `front` (the app's main window), or a document id in apps with document windows.
    public var window: String
    public var frame: DockFrame
    /// The display the frame is on (`NSScreenNumber`), when the chat app names it. Informational:
    /// the frame alone places the window.
    public var screen: Int?
    /// The chat app asking, as the app checked it (for the app's activity log).
    public var client: AgentClient?

    public init(window: String = DockingProtocol.frontWindow, frame: DockFrame, screen: Int? = nil,
                client: AgentClient? = nil) {
        self.window = window
        self.frame = frame
        self.screen = screen
        self.client = client
    }
}

/// Why the app let go of the window without being asked, for `docking/moved` and `docking/closed`.
public enum DockRelease: String, Sendable {
    /// The person dragged or resized the window themselves.
    case user
    /// Another chat app docked the window.
    case anotherClient
    /// The window closed.
    case windowClosed
    /// The app is quitting.
    case quit
}

/// What the app answers a placement with, or why it can't.
public enum DockPlacement: Sendable, Hashable {
    /// The frame the window took (the app may shorten it to fit the screen).
    case placed(DockFrame)
    /// The window doesn't exist, or can't be docked now (full screen); the message says why.
    case unavailable(String)
}

/// The app's windows, as the protocol moves them. Called one request at a time per window.
public protocol DockingWindows: AnyObject, Sendable {
    /// The narrowest width the window's layout works at, or nil when there's no such window.
    func minimumWidth(of window: String) async -> Double?
    /// Puts the window at the frame. `starting` is true for `docking/dock`: the app remembers
    /// its own size, place and layout to restore later, and brings the window forward.
    func place(_ request: DockRequest, starting: Bool) async -> DockPlacement
    /// Lets go. `restore` puts back the size and place the window had before docking; otherwise
    /// it stays where it is. Either way the app's own layout rules apply again.
    func release(_ window: String, restore: Bool, reason: DockRelease?) async
}

/// The way back to one chat app's connection, for notifications (`docking/moved`, …).
public final class MCPChannel: @unchecked Sendable {
    public let client: AgentClient
    private let lock = NSLock()
    private var output: (@Sendable (String) -> Bool)?

    init(client: AgentClient, output: (@Sendable (String) -> Bool)?) {
        self.client = client
        self.output = output
    }

    /// Sends a JSON-RPC notification; false when the connection is gone or has no way back.
    @discardableResult
    public func notify(_ method: String, _ params: JSONValue = .object([:])) -> Bool {
        let line = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]).compactText
        let output = lock.withLock { self.output }
        return output?(line) ?? false
    }

    func close() { lock.withLock { output = nil } }
}

/// Names and error codes of the protocol, version 1.
public enum DockingProtocol {
    public static let version = 1
    public static let frontWindow = "front"

    public static let dock = "docking/dock"
    public static let update = "docking/update"
    public static let undock = "docking/undock"
    public static let moved = "docking/moved"
    public static let closed = "docking/closed"
    public static let minWidth = "docking/minWidth"
    public static let methods: Set<String> = [dock, update, undock]

    /// The frame is narrower than the window's layout works at; `data.minWidth` says how wide.
    public static let tooNarrow = -32010
    /// The window doesn't exist or can't be docked now (full screen); the message says why.
    public static let unavailable = -32011
    /// `docking/update` from a chat app that hasn't docked the window (or lost it).
    public static let notDocked = -32012

    /// What the `initialize` result advertises under `capabilities.experimental.docking`.
    public static var capability: JSONValue {
        .object(["version": .int(version),
                 "requests": .array([dock, update, undock].map { .string($0) }),
                 "notifications": .array([moved, closed, minWidth].map { .string($0) })])
    }
}

/// Who holds each docked window, and the protocol's rules: one chat app at a time per window
/// (the newest dock wins and the previous one is told), frames below the minimum width are
/// refused, and a closed connection lets go. App-neutral: the app supplies `DockingWindows`.
public final class DockingCoordinator: @unchecked Sendable {
    private let windows: DockingWindows
    private let lock = NSLock()
    private var holders: [String: MCPChannel] = [:]

    public init(windows: DockingWindows) {
        self.windows = windows
    }

    /// The chat app docked to a window, if any.
    public func holder(of window: String = DockingProtocol.frontWindow) -> AgentClient? {
        lock.withLock { holders[window]?.client }
    }

    /// Handles a docking request from a granted client; returns the JSON-RPC result or error.
    func handle(_ method: String, _ params: [String: JSONValue], channel: MCPChannel) async -> Result<JSONValue, DockingFailure> {
        let window = params["window"]?.stringValue ?? DockingProtocol.frontWindow
        switch method {
        case DockingProtocol.undock:
            let restore = params["restore"]?.boolValue ?? false
            guard take(window, from: channel) else { return .success(.object([:])) }
            await windows.release(window, restore: restore, reason: nil)
            return .success(.object([:]))
        case DockingProtocol.dock, DockingProtocol.update:
            let starting = method == DockingProtocol.dock
            guard let frame = DockFrame(json: params["frame"]) else {
                return .failure(DockingFailure(code: -32602,
                                               message: "\(method) needs a frame: {\"x\", \"y\", \"width\", \"height\"} in points, width and height above 0"))
            }
            if !starting, lock.withLock({ holders[window] !== channel }) {
                return .failure(DockingFailure(code: DockingProtocol.notDocked,
                                               message: "This window isn't docked to you. Send \(DockingProtocol.dock) first."))
            }
            guard let minWidth = await windows.minimumWidth(of: window) else {
                return .failure(DockingFailure(code: DockingProtocol.unavailable, message: "There's no window \"\(window)\"."))
            }
            if frame.width < minWidth {
                return .failure(DockingFailure(code: DockingProtocol.tooNarrow,
                                               message: "The window needs at least \(Int(minWidth.rounded(.up))) points of width.",
                                               data: .object(["minWidth": .number(minWidth)])))
            }
            let screen = params["screen"]?.intValue
            // A new dock takes the window from whoever had it; they're told before it moves.
            if starting, let previous = lock.withLock({ () -> MCPChannel? in
                let previous = holders[window]
                return previous === channel ? nil : previous
            }) {
                previous.notify(DockingProtocol.moved, .object(["window": .string(window),
                                                                "reason": .string(DockRelease.anotherClient.rawValue)]))
            }
            switch await windows.place(DockRequest(window: window, frame: frame, screen: screen, client: channel.client), starting: starting) {
            case .unavailable(let message):
                if starting { _ = take(window, from: nil) }
                return .failure(DockingFailure(code: DockingProtocol.unavailable, message: message))
            case .placed(let taken):
                lock.withLock { holders[window] = channel }
                return .success(.object(["window": .string(window), "frame": taken.json, "minWidth": .number(minWidth)]))
            }
        default:
            return .failure(DockingFailure(code: -32601, message: "Method not found: \(method)"))
        }
    }

    /// The app's side: the person moved or resized the window, it closed, or the app is quitting.
    /// The chat app that held it is told, and the window is released (not restored).
    public func released(_ window: String = DockingProtocol.frontWindow, reason: DockRelease) async {
        guard let channel = lock.withLock({ holders.removeValue(forKey: window) }) else { return }
        let method = reason == .user || reason == .anotherClient ? DockingProtocol.moved : DockingProtocol.closed
        channel.notify(method, .object(["window": .string(window), "reason": .string(reason.rawValue)]))
        if reason == .user { await windows.release(window, restore: false, reason: reason) }
    }

    /// The same, for the app's last moments (quitting): sends the notifications at once.
    public func releaseAllNow(reason: DockRelease) {
        let all = lock.withLock { () -> [String: MCPChannel] in
            defer { holders.removeAll() }
            return holders
        }
        for (window, channel) in all {
            channel.notify(DockingProtocol.closed, .object(["window": .string(window), "reason": .string(reason.rawValue)]))
        }
    }

    /// The window's narrowest width changed (its layout changed); the holder is told.
    public func minimumWidthChanged(_ width: Double, window: String = DockingProtocol.frontWindow) {
        lock.withLock { holders[window] }?.notify(DockingProtocol.minWidth,
                                                 .object(["window": .string(window), "minWidth": .number(width)]))
    }

    /// A connection closed (the chat app quit, or its grant was changed or revoked): its windows
    /// are let go where they are.
    func closed(_ channel: MCPChannel) async {
        let windowsHeld = lock.withLock { () -> [String] in
            let held = holders.filter { $0.value === channel }.map(\.key)
            for window in held { holders[window] = nil }
            return held
        }
        for window in windowsHeld { await windows.release(window, restore: false, reason: nil) }
    }

    /// Clears the window's holder when it is `channel` (nil: whoever holds it). True if it was.
    private func take(_ window: String, from channel: MCPChannel?) -> Bool {
        lock.withLock {
            guard let holder = holders[window], channel == nil || holder === channel else { return false }
            holders[window] = nil
            return true
        }
    }
}

struct DockingFailure: Error {
    var code: Int
    var message: String
    var data: JSONValue?
}

/// A host whose windows can dock beside a chat app. The session advertises the protocol and
/// routes `docking/*` to `docking` (after the same grant check as every request; any profile,
/// Look included, may dock).
public protocol MCPDockingHost: MCPHost {
    var docking: DockingCoordinator? { get }
}
