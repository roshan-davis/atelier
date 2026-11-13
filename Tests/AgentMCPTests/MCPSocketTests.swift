import AgentActions
@testable import AgentMCP
import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#endif

/// The socket server and the helper relay, end to end, over a temporary socket.
final class MCPSocketTests: XCTestCase {
    var folder: URL!

    override func setUp() {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    var socketPath: String { folder.appendingPathComponent("s.sock").path }

    let fixedClient: @Sendable (Int32) -> AgentClient = { AgentClient(id: "test#TEAM", name: "Test", pid: $0) }

    /// A relay running on a thread, fed through pipes.
    final class RelayHarness: @unchecked Sendable {
        let toRelay = Pipe(), fromRelay = Pipe()
        var reader = LineReader()
        let finished = DispatchSemaphore(value: 0)
        var exitCode: Int32 = -1

        init(path: String, profile: String?, connectOnly: Bool = false) {
            let input = toRelay.fileHandleForReading.fileDescriptor
            let output = fromRelay.fileHandleForWriting.fileDescriptor
            let thread = Thread { [self] in
                exitCode = connectOnly ? MCPRelay.answerWithoutApp(input: input, output: output)
                    : MCPRelay.run(socketPath: path, requestedProfile: profile, input: input, output: output)
                finished.signal()
            }
            thread.start()
        }

        func send(_ line: String) { toRelay.fileHandleForWriting.write(Data((line + "\n").utf8)) }

        func receive(timeout: Double = 5) -> JSONValue? {
            let fd = fromRelay.fileHandleForReading.fileDescriptor
            var lines: [Data] = []
            let deadline = Date().addingTimeInterval(timeout)
            while lines.isEmpty, Date() < deadline {
                guard UnixSocket.waitReadable(fd, timeout: 0.1) else { continue }
                guard let batch = reader.read(from: fd) else { return nil }
                lines = batch
            }
            return lines.first.flatMap { JSONValue(parsing: $0) }
        }

        func closeInput() { try? toRelay.fileHandleForWriting.close() }
    }

    func testRelayReachesSessionAndCarriesProfileRequest() throws {
        let host = SketchMCPHost()
        host.allow("test#TEAM", .look)
        let server = MCPSocketServer(path: socketPath, host: host, identify: fixedClient)
        let connected = expectation(description: "connected")
        let seen = Box<AgentClient>()
        server.onConnect = { client in seen.value = client; connected.fulfill() }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let relay = RelayHarness(path: socketPath, profile: "edit")
        relay.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertEqual(relay.receive()?["result"]?["protocolVersion"], .string("2025-06-18"))
        wait(for: [connected], timeout: 5)
        XCTAssertEqual(seen.value?.requestedProfile, .edit)
        XCTAssertEqual(server.connectedClients.map(\.id), ["test#TEAM"])

        relay.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_documents"}}"#)
        XCTAssertEqual(relay.receive()?["result"]?["structuredContent"]?["documents"], .array([.string("Poster")]))

        relay.closeInput()
        XCTAssertEqual(relay.finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(relay.exitCode, 0)
    }

    func testDisconnectAndStopDropConnections() throws {
        let host = SketchMCPHost()
        host.allow("test#TEAM", .look)
        let server = MCPSocketServer(path: socketPath, host: host, identify: fixedClient)
        let gone = expectation(description: "disconnected")
        server.onDisconnect = { _ in gone.fulfill() }
        try server.start()

        let relay = RelayHarness(path: socketPath, profile: nil)
        relay.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(relay.receive()?["result"], .object([:]))

        server.disconnect(clientID: "test#TEAM")   // grant revoked in Settings
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(relay.finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(server.connectedClients.isEmpty)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(server.isRunning)
    }

    func testRelayWithoutAppAnswersEveryRequest() {
        let relay = RelayHarness(path: socketPath, profile: nil, connectOnly: true)
        relay.send(#"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}"#)
        let reply = relay.receive()
        XCTAssertEqual(reply?["id"], .int(7))
        XCTAssertEqual(reply?["error"]?["code"], .int(-32002))
        XCTAssertTrue(reply?["error"]?["message"]?.stringValue?.contains("Open Atelier") == true)
        relay.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        relay.closeInput()
        XCTAssertEqual(relay.finished.wait(timeout: .now() + 5), .success)
    }

    func testIdentityFindsOuterAppBundle() {
        XCTAssertEqual(ClientIdentity.outerBundle(in: "/Applications/Claude.app/Contents/Frameworks/Helper.app/Contents/MacOS/x"),
                       "/Applications/Claude.app")
        XCTAssertNil(ClientIdentity.outerBundle(in: "/usr/local/bin/opencode"))
        // On Linux there are no bundles: the client is named after the parent process.
        let me = ClientIdentity.client(forHelper: getpid())
        XCTAssertTrue(me.id.hasPrefix("process#"))
        XCTAssertEqual(me.pid, getpid())
    }

    func testLineReaderSplitsAndLimits() {
        var reader = LineReader()
        XCTAssertEqual(reader.add(Data("a\r\nb".utf8)), [Data("a".utf8)])
        XCTAssertEqual(reader.add(Data("c\n\n".utf8)), [Data("bc".utf8)])
        XCTAssertNil(reader.add(Data(repeating: 0x41, count: LineReader.limit + 1)))
    }

    func testSocketPathOverride() {
        setenv("SKETCH_MCP_SOCKET", "/tmp/x.sock", 1)
        defer { unsetenv("SKETCH_MCP_SOCKET") }
        XCTAssertEqual(AgentSocketPath.path(app: "Sketch"), "/tmp/x.sock")
        unsetenv("SKETCH_MCP_SOCKET")
        XCTAssertTrue(AgentSocketPath.path(app: "Sketch").hasSuffix("Sketch/Agents/sketch.sock"))
    }
}

final class Box<T>: @unchecked Sendable { var value: T? }
