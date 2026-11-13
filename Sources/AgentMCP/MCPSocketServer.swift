import AgentActions
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The app's MCP endpoint: a private Unix socket that the bundled helper connects to. Each
/// connection is identified from the socket peer (`ClientIdentity`), never from what it says,
/// and gets its own `MCPSession`. Stopping, or closing one client, drops its connections at once.
public final class MCPSocketServer: @unchecked Sendable {
    /// The first line a helper sends: `{"atelierHello":{"profile":"edit"}}`. Only a request.
    public static let helloKey = "atelierHello"

    public let path: String
    private let host: MCPHost
    private let identify: @Sendable (Int32) -> AgentClient
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections: [Int32: AgentClient] = [:]
    private var running = false
    /// Called with a client when it connects and when it goes (for the activity log).
    public var onConnect: (@Sendable (AgentClient) -> Void)?
    public var onDisconnect: (@Sendable (AgentClient) -> Void)?

    /// `identify` turns a peer's process id into a checked client (see `ClientIdentity.client(forHelper:)`).
    public init(path: String, host: MCPHost,
                identify: @escaping @Sendable (Int32) -> AgentClient = { ClientIdentity.client(forHelper: $0) }) {
        self.path = path
        self.host = host
        self.identify = identify
    }

    public var isRunning: Bool { lock.withLock { running } }

    public func start() throws {
        try lock.withLock {
            guard !running else { return }
            listener = try UnixSocket.listen(at: path)
            running = true
        }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "MCP accept"
        thread.start()
    }

    /// Closes the socket and every connection.
    public func stop() {
        let open: [Int32] = lock.withLock {
            guard running else { return [] }
            running = false
            close(listener)
            listener = -1
            unlink(path)
            let open = Array(connections.keys)
            connections.removeAll()
            return open
        }
        for fd in open { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    /// Drops one client's open connections (its grant was changed or revoked).
    public func disconnect(clientID: String) {
        let matching: [Int32] = lock.withLock {
            let matching = connections.filter { $0.value.id == clientID }.map(\.key)
            for fd in matching { connections[fd] = nil }
            return matching
        }
        for fd in matching { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    public var connectedClients: [AgentClient] { lock.withLock { Array(connections.values) } }

    private func acceptLoop() {
        while true {
            let fd: Int32 = lock.withLock { running ? listener : -1 }
            guard fd >= 0 else { return }
            guard UnixSocket.waitReadable(fd, timeout: 0.25) else { continue }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { continue }
            #if canImport(Darwin)
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            guard let peer = UnixSocket.peer(of: connection), peer.uid == getuid() else {
                close(connection)
                continue
            }
            let thread = Thread { [weak self] in self?.serve(connection, pid: peer.pid) }
            thread.name = "MCP connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32, pid: Int32) {
        var client = identify(pid)
        var reader = LineReader()
        var pending: [Data] = []
        // The helper's hello line (requested profile) comes first.
        while pending.isEmpty {
            guard let batch = reader.read(from: fd) else { close(fd); return }
            pending = batch
        }
        if let hello = JSONValue(parsing: pending[0])?[Self.helloKey] {
            pending.removeFirst()
            client.requestedProfile = hello["profile"]?.stringValue.flatMap(AgentProfile.init(rawValue:))
        }
        let registered: Bool = lock.withLock {
            guard running else { return false }
            connections[fd] = client
            return true
        }
        guard registered else { close(fd); return }
        onConnect?(client)

        let session = MCPSession(client: client, host: host)
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for await line in lines {
                if let reply = await session.handle(line) {
                    if !UnixSocket.write(fd, Data((reply + "\n").utf8)) { break }
                }
            }
            done.signal()
        }
        for line in pending { continuation.yield(line) }
        while let batch = reader.read(from: fd) {
            for line in batch { continuation.yield(line) }
        }
        continuation.finish()
        done.wait()
        lock.withLock { connections[fd] = nil }
        close(fd)
        onDisconnect?(session.client)
    }
}

/// The helper's side: relays stdin to the app's socket and the socket to stdout.
public enum MCPRelay {
    /// Runs until either side closes. Returns the process exit code.
    public static func run(socketPath: String, requestedProfile: String?,
                           input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: socketPath)
        } catch {
            return answerWithoutApp(input: input, output: output)
        }
        var hello: [String: JSONValue] = [:]
        if let requestedProfile { hello["profile"] = .string(requestedProfile) }
        guard UnixSocket.write(fd, Data((JSONValue.object([MCPSocketServer.helloKey: .object(hello)]).compactText + "\n").utf8)) else {
            return 1
        }
        defer { close(fd) }
        // One loop over both sides: no threads, so the relay can also run inside tests.
        var descriptors = [pollfd(fd: input, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            descriptors[0].revents = 0
            descriptors[1].revents = 0
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return 1
            }
            if descriptors[1].revents != 0 {
                // The app's side: replies, or closed (quit, access turned off, grant revoked).
                let count = Glibc_or_Darwin_read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0, writeAll(output, Data(buffer[0..<count])) else { return 0 }
            }
            if descriptors[0].revents != 0 {
                // The chat app's side: requests, or closed (it quit or stopped the server).
                let count = Glibc_or_Darwin_read(input, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0, UnixSocket.write(fd, Data(buffer[0..<count])) else {
                    shutdown(fd, Int32(SHUT_RDWR))
                    return 0
                }
            }
        }
    }

    /// Atelier isn't open: answer every request with an error the person can act on.
    static func answerWithoutApp(input: Int32, output: Int32) -> Int32 {
        var reader = LineReader()
        while let lines = reader.read(from: input) {
            for line in lines {
                guard let message = JSONValue(parsing: line), let id = message["id"], message["method"] != nil else { continue }
                let reply = MCPSession.error(id: id, code: -32002,
                                             message: "Atelier isn't running. Open Atelier, then try again.")
                _ = writeAll(output, Data((reply.compactText + "\n").utf8))
            }
        }
        return 0
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Glibc_or_Darwin_write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }
}

@inline(__always) func Glibc_or_Darwin_write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, buffer, count)
}
