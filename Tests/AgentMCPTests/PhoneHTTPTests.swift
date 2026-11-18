import AgentActions
@testable import AgentMCP
import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#endif

/// The phone contract (AT-050f, shared with Easel): tailnet-only binding, QR pairing, bearer
/// tokens kept as hashes, 401 and "revoked", sessions over Streamable HTTP. Uses the
/// Easel-shaped `SketchMCPHost`, so the module stays app-neutral.
final class PhoneHTTPTests: XCTestCase {
    var store: PhoneDeviceStore!
    var host: SketchMCPHost!
    var endpoint: MCPHTTPEndpoint!
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        store = PhoneDeviceStore(defaults: UserDefaults(suiteName: "phones-\(UUID().uuidString)")!, key: "phones")
        host = SketchMCPHost()
        // The app's authorize for a phone: its own grant from pairing.
        endpoint = MCPHTTPEndpoint(host: PhoneAwareHost(inner: host, store: store), devices: store, pairingProfile: { .edit })
    }

    // MARK: Tokens

    func testSHA256MatchesTheStandardVectors() {
        XCTAssertEqual(TokenHash.hash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(TokenHash.hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(TokenHash.hash(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testTokensAre32RandomBytesInBase64URL() {
        let a = TokenHash.newToken(), b = TokenHash.newToken()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 43)
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, a)
        XCTAssertTrue(TokenHash.equal("abc", "abc"))
        XCTAssertFalse(TokenHash.equal("abc", "abd"))
        XCTAssertFalse(TokenHash.equal("abc", "abcd"))
    }

    func testOnlyTheHashIsStored() throws {
        let defaults = UserDefaults(suiteName: "phones-\(UUID().uuidString)")!
        let store = PhoneDeviceStore(defaults: defaults, key: "phones")
        let code = store.startPairing(now: start)
        XCTAssertNotNil(store.completePairing(token: code.token, clientName: "Docent on iPhoneRo", profile: .edit, now: start))
        let saved = String(decoding: try XCTUnwrap(defaults.data(forKey: "phones")), as: UTF8.self)
        XCTAssertFalse(saved.contains(code.token))
        XCTAssertTrue(saved.contains(TokenHash.hash(code.token)))
    }

    // MARK: Where it listens

    func testTailnetRanges() {
        XCTAssertTrue(TailnetAddresses.isTailnet("100.64.0.1"))
        XCTAssertTrue(TailnetAddresses.isTailnet("100.101.102.103"))
        XCTAssertTrue(TailnetAddresses.isTailnet("100.127.255.254"))
        XCTAssertFalse(TailnetAddresses.isTailnet("100.63.255.255"))
        XCTAssertFalse(TailnetAddresses.isTailnet("100.128.0.1"))
        XCTAssertTrue(TailnetAddresses.isTailnet("fd7a:115c:a1e0::1"))
        XCTAssertTrue(TailnetAddresses.isTailnet("fd7a:115c:a1e0:ab12:4843:cd96:6258:b240"))
        XCTAssertFalse(TailnetAddresses.isTailnet("fd7a:115c:a1e1::1"))
        XCTAssertFalse(TailnetAddresses.isTailnet("192.168.1.20"))
        XCTAssertFalse(TailnetAddresses.isTailnet("0.0.0.0"))
        XCTAssertFalse(TailnetAddresses.isTailnet("::"))
        XCTAssertFalse(TailnetAddresses.isTailnet("roshs-mac"))
    }

    func testBindsLoopbackAndTailnetOnlyNeverWiFiOrAnyAddress() {
        let interfaces = [
            TailnetAddresses.Interface(name: "lo0", address: "127.0.0.1"),
            TailnetAddresses.Interface(name: "lo0", address: "::1"),
            TailnetAddresses.Interface(name: "en0", address: "192.168.1.20"),
            TailnetAddresses.Interface(name: "en0", address: "fe80::1c2b:3d4e%en0"),
            TailnetAddresses.Interface(name: "en0", address: "2a02:1234::5"),
            TailnetAddresses.Interface(name: "utun4", address: "fd7a:115c:a1e0::9a01:5c3f"),
            TailnetAddresses.Interface(name: "utun4", address: "100.101.102.103"),
        ]
        let bound = TailnetAddresses.bindAddresses(from: interfaces)
        XCTAssertEqual(bound, ["127.0.0.1", "100.101.102.103", "fd7a:115c:a1e0::9a01:5c3f"])
        XCTAssertFalse(bound.contains("0.0.0.0"))
        XCTAssertFalse(bound.contains("::"))
        XCTAssertFalse(bound.contains("192.168.1.20"))
        XCTAssertEqual(TailnetAddresses.preferredTailnetAddress(bound), "100.101.102.103")
    }

    func testNoTailscaleAddressMeansNothingIsBound() {
        let interfaces = [TailnetAddresses.Interface(name: "lo0", address: "127.0.0.1"),
                          TailnetAddresses.Interface(name: "en0", address: "192.168.1.20")]
        XCTAssertEqual(TailnetAddresses.bindAddresses(from: interfaces), [])
    }

    func testServerRefusesAnyOtherAddressBeforeBinding() {
        let server = MCPHTTPServer(endpoint: endpoint)
        for address in ["0.0.0.0", "::", "192.168.1.20", "10.0.0.5", "::1"] {
            XCTAssertThrowsError(try server.start(addresses: ["127.0.0.1", address], port: 0)) { error in
                XCTAssertEqual(error as? MCPHTTPServer.Failure, .notAllowed(address))
            }
            XCTAssertFalse(server.isRunning)
        }
    }

    func testThisMachinesInterfacesAreRead() {
        XCTAssertTrue(TailnetAddresses.currentInterfaces().contains { $0.address == "127.0.0.1" })
    }

    // MARK: Pairing

    func testQRPayloadIsVersionOne() throws {
        let code = PairingCode(token: "tok", expires: Date(timeIntervalSince1970: 1_800_000_300))
        let payload = try XCTUnwrap(JSONValue(parsing: Data(code.payload(app: "Atelier",
                                                                       url: PairingCode.url(host: "roshs-mac", port: 47801)).utf8)))
        XCTAssertEqual(payload["v"], .int(1))
        XCTAssertEqual(payload["app"], .string("Atelier"))
        XCTAssertEqual(payload["url"], .string("http://roshs-mac:47801/mcp"))
        XCTAssertEqual(payload["token"], .string("tok"))
        XCTAssertEqual(payload["expires"], .string("2027-01-15T08:05:00Z"))
        XCTAssertEqual(PairingCode.url(host: "fd7a:115c:a1e0::1", port: 47801), "http://[fd7a:115c:a1e0::1]:47801/mcp")
    }

    func testFirstInitializePairsTheDeviceAndTheTokenStaysItsCredential() async throws {
        let code = store.startPairing(now: start)
        let reply = await post(initialize(), token: code.token)
        XCTAssertEqual(reply.status, 200)
        let session = try XCTUnwrap(reply.headers[MCPHTTPEndpoint.sessionHeader])
        XCTAssertEqual(store.devices.map(\.name), ["Docent on iPhoneRo"])
        XCTAssertEqual(store.devices.first?.profile, .edit)
        // A new phone's own Allow card is its approval (as Easel): nobody may be at the Mac.
        XCTAssertEqual(store.devices.first?.asksForMe, true)
        XCTAssertNil(store.pendingPairing(now: start))
        let result = try XCTUnwrap(json(reply)?["result"])
        XCTAssertEqual(result["serverInfo"]?["name"], .string("sketch"))

        // The same token, now the device's own, lists and calls tools in its session.
        let tools = await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, token: code.token, session: session)
        XCTAssertEqual(tools.status, 200)
        XCTAssertEqual(json(tools)?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue },
                       ["list_documents", "rename_layer"])
        let call = await post(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_documents"}}"#,
                              token: code.token, session: session)
        XCTAssertEqual(json(call)?["result"]?["structuredContent"]?["documents"], .array([.string("Poster")]))
        // The host saw a phone, named from clientInfo.
        let caller = try XCTUnwrap(host.lock.withLock { host.calls.last })
        XCTAssertEqual(caller.0, "list_documents")
        XCTAssertTrue(caller.2.hasPrefix("phone#"))
        // A new session from the same phone also works.
        let again = await post(initialize(), token: code.token)
        XCTAssertEqual(again.status, 200)
        XCTAssertNotEqual(again.headers[MCPHTTPEndpoint.sessionHeader], session)
    }

    func testThePairingCodeOnlyPairsThroughInitialize() async {
        let code = store.startPairing(now: start)
        let reply = await post(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, token: code.token)
        XCTAssertEqual(reply.status, 401)
        XCTAssertTrue(store.devices.isEmpty)
    }

    func testThePairingCodeExpiresAfterFiveMinutes() async {
        let code = store.startPairing(now: start)
        XCTAssertEqual(code.expires.timeIntervalSince(start), 300)
        let late = await post(initialize(), token: code.token, now: start.addingTimeInterval(301))
        XCTAssertEqual(late.status, 401)
        XCTAssertTrue(late.body.isEmpty)
        XCTAssertTrue(store.devices.isEmpty)
        // Within the five minutes it pairs.
        let code2 = store.startPairing(now: start)
        let inTime = await post(initialize(), token: code2.token, now: start.addingTimeInterval(299))
        XCTAssertEqual(inTime.status, 200)
    }

    func testACodeWorksOnce() async {
        let code = store.startPairing(now: start)
        _ = await post(initialize(name: "Docent on iPhoneRo"), token: code.token)
        let stranger = await post(initialize(name: "Someone else"), token: code.token)
        // Now the first device's credential: it doesn't pair a second one.
        XCTAssertEqual(stranger.status, 200)
        XCTAssertEqual(store.devices.map(\.name), ["Docent on iPhoneRo"])
    }

    func testPairingTheSameDeviceAgainReplacesItsToken() async throws {
        let first = store.startPairing(now: start)
        _ = await post(initialize(), token: first.token)
        let id = try XCTUnwrap(store.devices.first?.id)
        store.update(id: id) { $0.profile = .organize; $0.asksForMe = true }
        let second = store.startPairing(now: start.addingTimeInterval(60))
        let reply = await post(initialize(), token: second.token, now: start.addingTimeInterval(60))
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.devices.first?.id, id)
        // Same grant, new token.
        XCTAssertEqual(store.devices.first?.profile, .organize)
        XCTAssertEqual(store.devices.first?.asksForMe, true)
        let old = await post(initialize(), token: first.token, now: start.addingTimeInterval(61))
        XCTAssertEqual(old.status, 401)
    }

    // MARK: 401

    func testNoTokenOrAWrongTokenIs401WithNoDetail() async {
        let code = store.startPairing(now: start)
        _ = await post(initialize(), token: code.token)
        let none = await endpoint.respond(to: HTTPRequest(method: "POST", path: "/mcp", headers: ["Content-Type": "application/json"],
                                                          body: Data(initialize().utf8)), now: start)
        XCTAssertEqual(none.status, 401)
        XCTAssertTrue(none.body.isEmpty)
        let wrong = await post(initialize(), token: TokenHash.newToken())
        XCTAssertEqual(wrong.status, 401)
        XCTAssertTrue(wrong.body.isEmpty)
        let basic = await endpoint.respond(to: HTTPRequest(method: "POST", path: "/mcp",
                                                           headers: ["Authorization": "Basic \(code.token)"],
                                                           body: Data(initialize().utf8)), now: start)
        XCTAssertEqual(basic.status, 401)
    }

    func testRevokeIs401RevokedAndEndsOpenSessionsAtOnce() async throws {
        let code = store.startPairing(now: start)
        let paired = await post(initialize(), token: code.token)
        let session = try XCTUnwrap(paired.headers[MCPHTTPEndpoint.sessionHeader])
        let id = try XCTUnwrap(store.devices.first?.id)
        XCTAssertEqual(endpoint.openSessions, 1)
        store.revoke(id: id)
        endpoint.dropSessions(deviceID: id)
        XCTAssertEqual(endpoint.openSessions, 0)
        let after = await post(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#, token: code.token, session: session)
        XCTAssertEqual(after.status, 401)
        XCTAssertEqual(json(after)?["error"]?["message"], .string("revoked"))
        XCTAssertEqual(json(after)?["id"], .int(7))
        XCTAssertTrue(store.devices.isEmpty)
    }

    func testRevokeWithoutDroppingSessionsStillStopsTheNextCall() async throws {
        let code = store.startPairing(now: start)
        let paired = await post(initialize(), token: code.token)
        let session = try XCTUnwrap(paired.headers[MCPHTTPEndpoint.sessionHeader])
        store.revoke(id: try XCTUnwrap(store.devices.first?.id))
        let after = await post(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_documents"}}"#,
                               token: code.token, session: session)
        XCTAssertEqual(after.status, 401)
        XCTAssertEqual(host.lock.withLock { host.calls.count }, 0)
    }

    // MARK: Streamable HTTP

    func testSessionsHeadersAndMethods() async throws {
        let code = store.startPairing(now: start)
        let paired = await post(initialize(), token: code.token)
        let session = try XCTUnwrap(paired.headers[MCPHTTPEndpoint.sessionHeader])
        // A notification is accepted with no body.
        let note = await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, token: code.token, session: session)
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)
        // Without the session header, or with one that ended: 400 and 404.
        let missing = await post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, token: code.token)
        XCTAssertEqual(missing.status, 400)
        // The same bodies as Easel's listener, so Docent reads both apps alike.
        XCTAssertEqual(JSONValue(parsing: missing.body)?["error"]?["message"], .string("Missing Mcp-Session-Id: send initialize first"))
        XCTAssertEqual(JSONValue(parsing: missing.body)?["id"], .int(2))
        let unknown = await post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, token: code.token, session: UUID().uuidString)
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(JSONValue(parsing: unknown.body)?["error"]?["code"], .int(-32001))
        XCTAssertEqual(JSONValue(parsing: unknown.body)?["error"]?["message"], .string("Session not found"))
        // GET (no server-sent stream) and other paths.
        let get = await endpoint.respond(to: HTTPRequest(method: "GET", path: "/mcp",
                                                         headers: ["Authorization": "Bearer \(code.token)"]), now: start)
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.headers["Allow"], "POST, DELETE")
        let elsewhere = await endpoint.respond(to: HTTPRequest(method: "POST", path: "/", headers: [:]), now: start)
        XCTAssertEqual(elsewhere.status, 404)
        // A browser page (any Origin) is refused, token or not.
        let browser = await endpoint.respond(to: HTTPRequest(method: "POST", path: "/mcp",
                                                             headers: ["Authorization": "Bearer \(code.token)",
                                                                       "Origin": "http://evil.example"],
                                                             body: Data(initialize().utf8)), now: start)
        XCTAssertEqual(browser.status, 403)
        // DELETE ends the session.
        let end = await endpoint.respond(to: HTTPRequest(method: "DELETE", path: "/mcp",
                                                         headers: ["Authorization": "Bearer \(code.token)",
                                                                   MCPHTTPEndpoint.sessionHeader: session]), now: start)
        XCTAssertEqual(end.status, 200)
        let gone = await post(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, token: code.token, session: session)
        XCTAssertEqual(gone.status, 404)
    }

    func testOneDeviceCantUseAnothersSession() async throws {
        let first = store.startPairing(now: start)
        let a = await post(initialize(name: "Phone A"), token: first.token)
        let sessionA = try XCTUnwrap(a.headers[MCPHTTPEndpoint.sessionHeader])
        let second = store.startPairing(now: start)
        _ = await post(initialize(name: "Phone B"), token: second.token)
        let crossed = await post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, token: second.token, session: sessionA)
        XCTAssertEqual(crossed.status, 404)
    }

    func testSessionsPerDeviceAreBoundedAndIdleOnesClose() async throws {
        let code = store.startPairing(now: start)
        var ids: [String] = []
        for _ in 0..<6 {
            let reply = await post(initialize(), token: code.token)
            ids.append(try XCTUnwrap(reply.headers[MCPHTTPEndpoint.sessionHeader]))
        }
        XCTAssertEqual(endpoint.openSessions, MCPHTTPEndpoint.sessionsPerDevice)
        let later = start.addingTimeInterval(MCPHTTPEndpoint.idleLimit + 1)
        let stale = await post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, token: code.token, session: ids.last!, now: later)
        XCTAssertEqual(stale.status, 404)
        XCTAssertEqual(endpoint.openSessions, 0)
    }

    func testDeniedPhoneGetsTheHostsReason() async throws {
        let code = store.startPairing(now: start)
        _ = await post(initialize(), token: code.token)
        let id = try XCTUnwrap(store.devices.first?.id)
        (endpoint.host as? PhoneAwareHost)?.deny(id)
        let reply = await post(initialize(), token: code.token)
        XCTAssertEqual(reply.status, 200)
        XCTAssertNil(reply.headers[MCPHTTPEndpoint.sessionHeader])
        XCTAssertEqual(json(reply)?["error"]?["code"], .int(-32001))
    }

    // MARK: Parsing

    func testRequestParsing() {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: roshs-mac:47801\r\nAuthorization: Bearer abc\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.headers["authorization"], "Bearer abc")
        XCTAssertEqual(request.body, Data("{}".utf8))
        guard case .incomplete = HTTPRequest.parse(Data(raw.dropLast().utf8)) else { return XCTFail() }
        guard case .failed(411) = HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\n\r\n".utf8)) else { return XCTFail() }
        guard case .failed(413) = HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) else {
            return XCTFail()
        }
        guard case .failed(501) = HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else {
            return XCTFail()
        }
        guard case .failed(431) = HTTPRequest.parse(Data(String(repeating: "x", count: HTTPRequest.headerLimit + 1).utf8)) else {
            return XCTFail()
        }
    }

    // MARK: Over a real socket on 127.0.0.1

    func testOverTCPOnLoopback() throws {
        let server = MCPHTTPServer(endpoint: endpoint)
        try server.start(addresses: ["127.0.0.1"], port: 0)
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)
        let code = store.startPairing()
        let unauthorized = try rawRequest(port: server.port, body: initialize(), token: nil)
        XCTAssertTrue(unauthorized.hasPrefix("HTTP/1.1 401"), unauthorized)
        let paired = try rawRequest(port: server.port, body: initialize(), token: code.token)
        XCTAssertTrue(paired.hasPrefix("HTTP/1.1 200"), paired)
        XCTAssertTrue(paired.contains("Mcp-Session-Id: "), paired)
        XCTAssertTrue(paired.contains("\"serverInfo\""), paired)
        server.stop()
        XCTAssertThrowsError(try rawRequest(port: server.port, body: initialize(), token: code.token))
    }

    // MARK: Helpers

    func initialize(name: String = "Docent on iPhoneRo") -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"\#(name)","version":"1"}}}"#
    }

    func post(_ body: String, token: String?, session: String? = nil, now: Date? = nil) async -> HTTPResponse {
        var headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let session { headers[MCPHTTPEndpoint.sessionHeader] = session }
        return await endpoint.respond(to: HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(body.utf8)),
                                      now: now ?? start)
    }

    func json(_ response: HTTPResponse) -> JSONValue? { JSONValue(parsing: response.body) }

    func rawRequest(port: UInt16, body: String, token: String?) throws -> String {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw MCPHTTPServer.Failure.system("connect", errno) }
        var request = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        if let token { request += "Authorization: Bearer \(token)\r\n" }
        request += "\r\n" + body
        _ = UnixSocket.write(fd, Data(request.utf8))
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            reply.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: reply, as: UTF8.self)
    }
}

/// The app's side of authorize for phones: a paired device is allowed its own profile, without
/// asking anyone (the Sketch host would deny an unknown client).
final class PhoneAwareHost: MCPHost, @unchecked Sendable {
    let inner: SketchMCPHost
    let store: PhoneDeviceStore
    private let lock = NSLock()
    private var denied: Set<String> = []

    init(inner: SketchMCPHost, store: PhoneDeviceStore) {
        self.inner = inner
        self.store = store
    }

    func deny(_ id: String) { lock.withLock { _ = denied.insert(id) } }

    var serverInfo: MCPServerInfo { inner.serverInfo }

    func authorize(_ client: AgentClient) async -> AgentAuthorization {
        guard client.isRemote, let id = PairedDevice.deviceID(fromClientID: client.id), let device = store.device(id: id),
              !lock.withLock({ denied.contains(id) }) else { return .denied("This phone isn't paired.") }
        return .allowed(device.profile)
    }

    func tools(for client: AgentClient, profile: AgentProfile) async -> [MCPTool] {
        await inner.tools(for: client, profile: profile)
    }

    func call(_ tool: String, arguments: [String: JSONValue], client: AgentClient, profile: AgentProfile) async -> MCPToolResult {
        await inner.call(tool, arguments: arguments, client: client, profile: profile)
    }
}
