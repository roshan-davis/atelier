import AgentActions
@testable import AgentMCP
import Foundation
import XCTest

/// Easel-shaped windows: a front window and a document window ("poster"), 600 points at least.
final class SketchWindows: DockingWindows, @unchecked Sendable {
    let lock = NSLock()
    var frames: [String: DockFrame] = ["front": DockFrame(x: 100, y: 100, width: 1200, height: 800),
                                       "poster": DockFrame(x: 0, y: 0, width: 900, height: 700)]
    var saved: [String: DockFrame] = [:]
    var fullScreen = false
    var releases: [(String, Bool, DockRelease?)] = []
    /// The screen's top: a taller frame is shortened to fit.
    let screenTop = 1000.0

    func minimumWidth(of window: String) async -> Double? {
        lock.withLock { frames[window] == nil ? nil : 600 }
    }

    func place(_ request: DockRequest, starting: Bool) async -> DockPlacement {
        lock.withLock {
            guard let current = frames[request.window] else { return .unavailable("No such window") }
            if fullScreen { return .unavailable("Sketch is in full screen.") }
            if starting, saved[request.window] == nil { saved[request.window] = current }
            var frame = request.frame
            frame.height = min(frame.height, screenTop - frame.y)
            frames[request.window] = frame
            return .placed(frame)
        }
    }

    func release(_ window: String, restore: Bool, reason: DockRelease?) async {
        lock.withLock {
            releases.append((window, restore, reason))
            if restore, let saved = saved[window] { frames[window] = saved }
            saved[window] = nil
        }
    }
}

final class SketchDockingHost: MCPDockingHost, @unchecked Sendable {
    let base = SketchMCPHost()
    let windows = SketchWindows()
    lazy var coordinator = DockingCoordinator(windows: windows)
    var docking: DockingCoordinator? { coordinator }
    var serverInfo: MCPServerInfo { base.serverInfo }
    func authorize(_ client: AgentClient) async -> AgentAuthorization { await base.authorize(client) }
    func tools(for client: AgentClient, profile: AgentProfile) async -> [MCPTool] { await base.tools(for: client, profile: profile) }
    func call(_ tool: String, arguments: [String: JSONValue], client: AgentClient, profile: AgentProfile) async -> MCPToolResult {
        await base.call(tool, arguments: arguments, client: client, profile: profile)
    }
}

/// What a session sent outside its replies.
final class Outbox: @unchecked Sendable {
    let lock = NSLock()
    var lines: [JSONValue] = []
    var open = true
    lazy var send: @Sendable (String) -> Bool = { [unowned self] line in
        self.lock.withLock {
            guard self.open else { return false }
            if let value = JSONValue(parsing: Data(line.utf8)) { self.lines.append(value) }
            return true
        }
    }
    var methods: [String] { lock.withLock { lines.compactMap { $0["method"]?.stringValue } } }
}

final class DockingTests: XCTestCase {
    let docent = AgentClient(id: "com.example.docent#TEAM", name: "Docent", pid: 7)
    let other = AgentClient(id: "com.example.chat#TEAM", name: "Chat", pid: 8)

    func send(_ session: MCPSession, _ method: String, _ params: String = "{}", id: Int = 1) async -> JSONValue? {
        let text = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        guard let reply = await session.handle(Data(text.utf8)) else { return nil }
        return JSONValue(parsing: Data(reply.utf8))
    }

    func session(_ host: SketchDockingHost, _ client: AgentClient, _ outbox: Outbox, profile: AgentProfile = .look) -> MCPSession {
        host.base.allow(client.id, profile)
        return MCPSession(client: client, host: host, output: outbox.send)
    }

    let frame = #"{"frame":{"x":800,"y":100,"width":900,"height":800},"screen":1}"#

    func testCapabilityIsAdvertisedOnlyWithDockingAndAWayBack() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let docking = session(host, docent, outbox)
        let reply = await send(docking, "initialize", #"{"protocolVersion":"2025-06-18"}"#)
        let capability = reply?["result"]?["capabilities"]?["experimental"]?["docking"]
        XCTAssertEqual(capability?["version"], .int(DockingProtocol.version))
        XCTAssertEqual(capability?["requests"]?.arrayValue?.count, 3)

        // A plain host (no docking) and a session without output don't advertise it or answer it.
        let plain = SketchMCPHost()
        plain.allow(docent.id, .look)
        for session in [MCPSession(client: docent, host: plain, output: outbox.send), MCPSession(client: docent, host: host)] {
            let initialize = await send(session, "initialize", #"{"protocolVersion":"2025-06-18"}"#)
            XCTAssertNil(initialize?["result"]?["capabilities"]?["experimental"])
            let dock = await send(session, DockingProtocol.dock, frame)
            XCTAssertEqual(dock?["error"]?["code"], .int(-32601))
        }
    }

    /// A setting that adds or removes tools tells the client to list them again (MCP
    /// notifications/tools/list_changed), but only after initialize and with a way back.
    func testToolsChangedIsAdvertisedAndSentAfterInitialize() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let live = session(host, docent, outbox)
        XCTAssertFalse(live.toolsChanged(), "nothing before initialize")
        let reply = await send(live, "initialize", #"{"protocolVersion":"2025-06-18"}"#)
        XCTAssertEqual(reply?["result"]?["capabilities"]?["tools"]?["listChanged"], .bool(true))
        XCTAssertTrue(live.toolsChanged())
        XCTAssertEqual(outbox.methods, [MCPSession.toolsListChanged])

        // Without a way back the session can't send it, so it doesn't promise it.
        let answersOnly = MCPSession(client: docent, host: host)
        let plain = await send(answersOnly, "initialize", #"{"protocolVersion":"2025-06-18"}"#)
        XCTAssertEqual(plain?["result"]?["capabilities"]?["tools"]?["listChanged"], .bool(false))
        XCTAssertFalse(answersOnly.toolsChanged())
    }

    func testDockingMethodsAreNeverTools() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let session = session(host, docent, outbox, profile: .everything)
        let list = await send(session, "tools/list")
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertFalse(names.isEmpty)
        XCTAssertFalse(names.contains { $0.contains("dock") })
        // And tools/call can't reach them by name.
        let call = await send(session, "tools/call", #"{"name":"docking/dock","arguments":{}}"#)
        XCTAssertEqual(call?["error"]?["code"], .int(-32602))
        XCTAssertNil(host.coordinator.holder())
    }

    func testDockUpdateUndockAnswersWithTheFrameTaken() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let session = session(host, docent, outbox)
        let dock = await send(session, DockingProtocol.dock, frame)
        XCTAssertEqual(dock?["result"]?["frame"]?["x"]?.doubleValue, 800)
        // 100 + 800 is under the screen's top (1000), so the height stays.
        XCTAssertEqual(dock?["result"]?["frame"]?["height"]?.doubleValue, 800)
        XCTAssertEqual(dock?["result"]?["minWidth"]?.doubleValue, 600)
        XCTAssertEqual(host.coordinator.holder()?.id, docent.id)

        let update = await send(session, DockingProtocol.update,
                                #"{"frame":{"x":700,"y":300,"width":1000,"height":900}}"#, id: 2)
        XCTAssertEqual(update?["result"]?["frame"]?["height"]?.doubleValue, 700, "shortened to fit the screen")
        XCTAssertEqual(host.windows.frames["front"]?.x, 700)

        let undock = await send(session, DockingProtocol.undock, #"{"restore":true}"#, id: 3)
        XCTAssertEqual(undock?["result"], .object([:]))
        XCTAssertNil(host.coordinator.holder())
        XCTAssertEqual(host.windows.frames["front"], DockFrame(x: 100, y: 100, width: 1200, height: 800), "restored")
        XCTAssertTrue(outbox.methods.isEmpty, "asked-for changes send no notifications")
    }

    func testRefusalsNameTheProblem() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let session = session(host, docent, outbox)
        let narrow = await send(session, DockingProtocol.dock, #"{"frame":{"x":0,"y":0,"width":400,"height":800}}"#)
        XCTAssertEqual(narrow?["error"]?["code"], .int(DockingProtocol.tooNarrow))
        XCTAssertEqual(narrow?["error"]?["data"]?["minWidth"]?.doubleValue, 600)
        XCTAssertNil(host.coordinator.holder())

        let noFrame = await send(session, DockingProtocol.dock, #"{"frame":{"x":0,"y":0,"width":0,"height":800}}"#)
        XCTAssertEqual(noFrame?["error"]?["code"], .int(-32602))
        let noWindow = await send(session, DockingProtocol.dock, #"{"window":"flyer","frame":{"x":0,"y":0,"width":900,"height":800}}"#)
        XCTAssertEqual(noWindow?["error"]?["code"], .int(DockingProtocol.unavailable))
        let notDocked = await send(session, DockingProtocol.update, frame)
        XCTAssertEqual(notDocked?["error"]?["code"], .int(DockingProtocol.notDocked))

        host.windows.fullScreen = true
        let full = await send(session, DockingProtocol.dock, frame)
        XCTAssertEqual(full?["error"]?["message"], .string("Sketch is in full screen."))
        XCTAssertNil(host.coordinator.holder())
    }

    func testOnlyAGrantedClientDocks() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let session = MCPSession(client: docent, host: host, output: outbox.send)
        let dock = await send(session, DockingProtocol.dock, frame)
        XCTAssertEqual(dock?["error"]?["code"], .int(-32001))
        XCTAssertNil(host.coordinator.holder())
    }

    func testDocumentWindowsDockOnTheirOwn() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let session = session(host, docent, outbox)
        let dock = await send(session, DockingProtocol.dock, #"{"window":"poster","frame":{"x":800,"y":100,"width":900,"height":800}}"#)
        XCTAssertEqual(dock?["result"]?["window"], .string("poster"))
        XCTAssertEqual(host.coordinator.holder(of: "poster")?.id, docent.id)
        XCTAssertNil(host.coordinator.holder())
    }

    func testANewDockTakesTheWindowAndTellsThePreviousHolder() async {
        let host = SketchDockingHost()
        let first = Outbox(), second = Outbox()
        let one = session(host, docent, first)
        let two = session(host, other, second)
        _ = await send(one, DockingProtocol.dock, frame)
        _ = await send(two, DockingProtocol.dock, frame)
        XCTAssertEqual(host.coordinator.holder()?.id, other.id)
        XCTAssertEqual(first.methods, [DockingProtocol.moved])
        XCTAssertEqual(first.lines.first?["params"]?["reason"], .string("anotherClient"))
        XCTAssertTrue(second.methods.isEmpty)
        // The first one's updates are refused now; its undock doesn't touch the other's dock.
        let update = await send(one, DockingProtocol.update, frame, id: 2)
        XCTAssertEqual(update?["error"]?["code"], .int(DockingProtocol.notDocked))
        _ = await send(one, DockingProtocol.undock, "{}", id: 3)
        XCTAssertEqual(host.coordinator.holder()?.id, other.id)
    }

    func testTheAppTellsTheHolderWhenItLetsGo() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let session = session(host, docent, outbox)
        _ = await send(session, DockingProtocol.dock, frame)
        host.coordinator.minimumWidthChanged(640)
        await host.coordinator.released(reason: .user)
        XCTAssertEqual(outbox.methods, [DockingProtocol.minWidth, DockingProtocol.moved])
        XCTAssertEqual(outbox.lines[0]["params"]?["minWidth"]?.doubleValue, 640)
        XCTAssertEqual(outbox.lines[1]["params"]?["reason"], .string("user"))
        XCTAssertEqual(host.windows.releases.last?.1, false, "the window stays where the person put it")
        XCTAssertNil(host.coordinator.holder())
        // Nothing more once it's let go.
        host.coordinator.minimumWidthChanged(600)
        XCTAssertEqual(outbox.methods.count, 2)

        _ = await send(session, DockingProtocol.dock, frame, id: 2)
        await host.coordinator.released(reason: .windowClosed)
        XCTAssertEqual(outbox.methods.last, DockingProtocol.closed)
        _ = await send(session, DockingProtocol.dock, frame, id: 3)
        host.coordinator.releaseAllNow(reason: .quit)
        XCTAssertEqual(outbox.lines.last?["params"]?["reason"], .string("quit"))
        XCTAssertNil(host.coordinator.holder())
    }

    func testAClosedConnectionLetsGoWhereItIs() async {
        let host = SketchDockingHost()
        let outbox = Outbox()
        let session = session(host, docent, outbox)
        _ = await send(session, DockingProtocol.dock, frame)
        await session.close()
        XCTAssertNil(host.coordinator.holder())
        XCTAssertEqual(host.windows.releases.count, 1)
        XCTAssertEqual(host.windows.releases.first?.1, false)
        XCTAssertEqual(host.windows.frames["front"]?.x, 800)
    }
}
