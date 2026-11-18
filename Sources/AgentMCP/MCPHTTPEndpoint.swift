import AgentActions
import Foundation

/// One HTTP request, as `MCPHTTPServer` read it.
public struct HTTPRequest: Sendable {
    public var method: String
    /// The path without its query.
    public var path: String
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.body = body
    }

    public static let headerLimit = 16 * 1024
    /// A request bigger than this is refused (MCP requests are small; images only go out).
    public static let bodyLimit = 4 * 1024 * 1024

    public enum Parse {
        case incomplete
        case complete(HTTPRequest)
        case failed(status: Int)
    }

    /// Reads a whole request from the start of `buffer`: HTTP/1.1, Content-Length bodies only.
    public static func parse(_ buffer: Data) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > headerLimit ? .failed(status: 431) : .incomplete
        }
        guard end.lowerBound <= headerLimit,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .failed(status: 431)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .failed(status: 400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failed(status: 400) }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .failed(status: 400) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .failed(status: 501) }
        let method = String(requestLine[0])
        var length = 0
        if let text = headers["content-length"] {
            guard let value = Int(text), value >= 0 else { return .failed(status: 400) }
            length = value
        } else if method == "POST" {
            return .failed(status: 411)
        }
        guard length <= bodyLimit else { return .failed(status: 413) }
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return .complete(HTTPRequest(method: method, path: path, headers: headers,
                                     body: Data(buffer[bodyStart..<(bodyStart + length)])))
    }
}

/// One HTTP response.
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> HTTPResponse {
        var all = headers
        all["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: all, body: Data(text.utf8))
    }

    public var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for name in all.keys.sorted() { head += "\(name): \(all[name]!)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// MCP's Streamable HTTP transport at `/mcp` for paired phones (AT-050f): the same sessions,
/// tools, resources and views as the local helper, behind a bearer token. Each POST carries one
/// JSON-RPC message and is answered with one JSON reply (no server-sent events: nothing on this
/// connection needs to reach the phone unasked). Socket-free, so the whole contract is tested
/// without a network; `MCPHTTPServer` puts it on the tailnet.
public final class MCPHTTPEndpoint: @unchecked Sendable {
    public static let path = "/mcp"
    public static let sessionHeader = "Mcp-Session-Id"
    /// Open sessions per device; the oldest goes when a phone starts another.
    static let sessionsPerDevice = 4
    /// A session unused this long is closed (the phone initializes again).
    static let idleLimit: TimeInterval = 60 * 60

    public let devices: PhoneDeviceStore
    let host: MCPHost
    /// The profile a newly paired phone gets (the app's choice, such as Docent's on the Mac).
    private let pairingProfile: @Sendable () -> AgentProfile
    /// A phone just paired (the app closes the code and logs it).
    public var onPaired: (@Sendable (PairedDevice) -> Void)?

    private let lock = NSLock()
    private var sessions: [String: Entry] = [:]

    final class Entry: @unchecked Sendable {
        let deviceID: String
        let session: MCPSession
        let gate = SerialGate()
        var lastUsed: Date
        init(deviceID: String, session: MCPSession, lastUsed: Date) {
            self.deviceID = deviceID
            self.session = session
            self.lastUsed = lastUsed
        }
    }

    public init(host: MCPHost, devices: PhoneDeviceStore, pairingProfile: @escaping @Sendable () -> AgentProfile) {
        self.host = host
        self.devices = devices
        self.pairingProfile = pairingProfile
    }

    /// How many sessions are open (Settings, tests).
    public var openSessions: Int { lock.withLock { sessions.count } }

    /// Closes a device's sessions at once (Revoke).
    public func dropSessions(deviceID: String) {
        let gone: [Entry] = lock.withLock {
            let matching = sessions.filter { $0.value.deviceID == deviceID }
            for key in matching.keys { sessions[key] = nil }
            return Array(matching.values)
        }
        for entry in gone { Task { await entry.session.close() } }
    }

    public func dropAll() {
        let gone: [Entry] = lock.withLock {
            let all = Array(sessions.values)
            sessions.removeAll()
            return all
        }
        for entry in gone { Task { await entry.session.close() } }
    }

    public func respond(to request: HTTPRequest, now: Date = Date()) async -> HTTPResponse {
        guard request.path == Self.path else { return HTTPResponse(status: 404) }
        // A web page can't reach the listener through the person's browser (DNS rebinding):
        // the phone app sends no Origin, a browser always does.
        if request.headers["origin"] != nil { return HTTPResponse(status: 403) }
        switch request.method {
        case "POST", "DELETE": break
        default: return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }
        guard let token = Self.bearer(request.headers["authorization"]) else { return Self.unauthorized }
        let message = request.method == "POST" ? JSONValue(parsing: request.body) : nil

        let device: PairedDevice
        switch devices.check(token: token, now: now) {
        case .device(let found):
            device = found
        case .revoked:
            let id = message?["id"] ?? .null
            return .json(401, MCPSession.error(id: id, code: -32001, message: "revoked").compactText,
                         headers: ["WWW-Authenticate": "Bearer error=\"invalid_token\""])
        case .pairing:
            // The code pairs only through its first initialize.
            guard message?["method"]?.stringValue == "initialize",
                  let paired = devices.completePairing(token: token,
                                                       clientName: message?["params"]?["clientInfo"]?["name"]?.stringValue,
                                                       profile: pairingProfile(), now: now) else { return Self.unauthorized }
            dropSessions(deviceID: paired.id)
            onPaired?(paired)
            device = paired
        case .unknown:
            return Self.unauthorized
        }
        devices.touch(id: device.id, now: now)
        sweep(now)

        if request.method == "DELETE" {
            guard let id = request.headers[Self.sessionHeader.lowercased()] else { return HTTPResponse(status: 400) }
            let entry: Entry? = lock.withLock {
                guard let entry = sessions[id], entry.deviceID == device.id else { return nil }
                sessions[id] = nil
                return entry
            }
            guard let entry else { return HTTPResponse(status: 404) }
            await entry.session.close()
            return HTTPResponse(status: 200)
        }

        guard let message else {
            return .json(400, MCPSession.error(id: .null, code: -32700, message: "Parse error: not JSON").compactText)
        }
        if message["method"]?.stringValue == "initialize" {
            return await initialize(request, device: device, now: now)
        }
        guard let id = request.headers[Self.sessionHeader.lowercased()] else {
            return .json(400, MCPSession.error(id: message["id"] ?? .null, code: -32600,
                                               message: "Send initialize first, then the \(Self.sessionHeader) header it returns.").compactText)
        }
        let entry: Entry? = lock.withLock {
            guard let entry = sessions[id], entry.deviceID == device.id else { return nil }
            entry.lastUsed = now
            return entry
        }
        // 404: the session ended (idle, revoked, the app restarted); the phone initializes again.
        guard let entry else { return HTTPResponse(status: 404) }
        let reply = await entry.gate.run { await entry.session.handle(request.body) }
        guard let reply else { return HTTPResponse(status: 202) }
        return .json(200, reply, headers: [Self.sessionHeader: id])
    }

    private func initialize(_ request: HTTPRequest, device: PairedDevice, now: Date) async -> HTTPResponse {
        let session = MCPSession(client: device.client, host: host)
        guard let reply = await session.handle(request.body) else { return HTTPResponse(status: 202) }
        guard let parsed = JSONValue(parsing: Data(reply.utf8)), parsed["result"] != nil else { return .json(200, reply) }
        let id = UUID().uuidString
        let dropped: [Entry] = lock.withLock {
            sessions[id] = Entry(deviceID: device.id, session: session, lastUsed: now)
            let mine = sessions.filter { $0.value.deviceID == device.id }.sorted { $0.value.lastUsed < $1.value.lastUsed }
            let extra = mine.prefix(max(0, mine.count - Self.sessionsPerDevice))
            for (key, _) in extra { sessions[key] = nil }
            return extra.map(\.value)
        }
        for entry in dropped { await entry.session.close() }
        return .json(200, reply, headers: [Self.sessionHeader: id])
    }

    private func sweep(_ now: Date) {
        let gone: [Entry] = lock.withLock {
            let old = sessions.filter { now.timeIntervalSince($0.value.lastUsed) > Self.idleLimit }
            for key in old.keys { sessions[key] = nil }
            return Array(old.values)
        }
        for entry in gone { Task { await entry.session.close() } }
    }

    static let unauthorized = HTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])

    static func bearer(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

/// Runs one task at a time, in arrival order (a session handles its messages in order, as on
/// the socket).
final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let value = await body()
        release()
        return value
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go: Bool = lock.withLock {
                if busy { waiting.append(continuation); return false }
                busy = true
                return true
            }
            if go { continuation.resume() }
        }
    }

    private func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiting.isEmpty { busy = false; return nil }
            return waiting.removeFirst()
        }
        next?.resume()
    }
}
