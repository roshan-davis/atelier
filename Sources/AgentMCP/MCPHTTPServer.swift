import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Puts `MCPHTTPEndpoint` on TCP: one listening socket per allowed address (127.0.0.1 and the
/// tailnet addresses; anything else is refused before binding), one short-lived thread per
/// request, `Connection: close`. Bounded: at most `connectionLimit` requests at once, a 30 s
/// read timeout, the request size limits in `HTTPRequest`.
public final class MCPHTTPServer: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Not 127.0.0.1 or a tailnet address: never bound.
        case notAllowed(String)
        case portInUse(UInt16)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .notAllowed(let address): return "\(address) isn't 127.0.0.1 or a Tailscale address"
            case .portInUse(let port): return "Port \(port) is in use by another app"
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    public let endpoint: MCPHTTPEndpoint
    static let connectionLimit = 16
    static let readTimeout: Int = 30

    private let lock = NSLock()
    private var listeners: [Int32] = []
    private var running = false
    private var active = 0
    public private(set) var boundAddresses: [String] = []
    public private(set) var port: UInt16 = 0

    public init(endpoint: MCPHTTPEndpoint) {
        self.endpoint = endpoint
    }

    public var isRunning: Bool { lock.withLock { running } }

    /// Listens on `addresses` at `port` (0: any free port, for tests). Every address must pass
    /// `TailnetAddresses.isAllowedBindAddress`.
    public func start(addresses: [String], port requested: UInt16) throws {
        for address in addresses where !TailnetAddresses.isAllowedBindAddress(address) {
            throw Failure.notAllowed(address)
        }
        stop()
        var sockets: [Int32] = []
        var port = requested
        do {
            for address in addresses {
                let fd = try Self.listen(address: address, port: port)
                sockets.append(fd)
                if port == 0 { port = Self.localPort(of: fd) }
            }
        } catch {
            for fd in sockets { close(fd) }
            throw error
        }
        let opened = sockets
        lock.withLock {
            listeners = opened
            boundAddresses = addresses
            self.port = port
            running = true
        }
        let thread = Thread { [weak self] in self?.acceptLoop(opened) }
        thread.name = "MCP HTTP accept"
        thread.start()
    }

    /// Closes the listening sockets and every open session.
    public func stop() {
        let open: [Int32] = lock.withLock {
            guard running else { return [] }
            running = false
            let open = listeners
            listeners = []
            boundAddresses = []
            return open
        }
        // shutdown first: it stops listening at once, even while the accept loop's poll holds the socket.
        for fd in open {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
        if !open.isEmpty { endpoint.dropAll() }
    }

    private func acceptLoop(_ fds: [Int32]) {
        var descriptors = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        while lock.withLock({ running && listeners == fds }) {
            for index in descriptors.indices { descriptors[index].revents = 0 }
            guard poll(&descriptors, nfds_t(descriptors.count), 250) > 0,
                  lock.withLock({ running && listeners == fds }) else { continue }
            for descriptor in descriptors where descriptor.revents & Int16(POLLIN) != 0 {
                let connection = accept(descriptor.fd, nil, nil)
                guard connection >= 0 else { continue }
                Self.configure(connection)
                let admitted: Bool = lock.withLock {
                    guard active < Self.connectionLimit else { return false }
                    active += 1
                    return true
                }
                guard admitted else {
                    _ = UnixSocket.write(connection, HTTPResponse(status: 503).serialized)
                    close(connection)
                    continue
                }
                let thread = Thread { [weak self] in
                    self?.serve(connection)
                    self?.lock.withLock { self?.active -= 1 }
                }
                thread.name = "MCP HTTP request"
                thread.start()
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let request: HTTPRequest
        reading: while true {
            switch HTTPRequest.parse(buffer) {
            case .complete(let complete):
                request = complete
                break reading
            case .failed(let status):
                _ = UnixSocket.write(fd, HTTPResponse(status: status).serialized)
                return
            case .incomplete:
                let count = Glibc_or_Darwin_read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        _ = UnixSocket.write(fd, HTTPResponse(status: 408).serialized)
                    }
                    return
                }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }
        let done = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let endpoint = self.endpoint
        Task.detached {
            box.response = await endpoint.respond(to: request)
            done.signal()
        }
        done.wait()
        _ = UnixSocket.write(fd, (box.response ?? HTTPResponse(status: 503)).serialized)
    }

    final class ResponseBox: @unchecked Sendable { var response: HTTPResponse? }

    // MARK: Sockets

    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: readTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func listen(address: String, port: UInt16) throws -> Int32 {
        let isIPv4 = TailnetAddresses.ipv4(address) != nil
        guard isIPv4 || TailnetAddresses.ipv6(address) != nil else { throw Failure.notAllowed(address) }
        #if os(Linux)
        let fd = socket(isIPv4 ? AF_INET : AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(isIPv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let result: Int32
        if isIPv4 {
            var socketAddress = sockaddr_in()
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = port.bigEndian
            #if canImport(Darwin)
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            _ = inet_pton(AF_INET, address, &socketAddress.sin_addr)
            result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = port.bigEndian
            #if canImport(Darwin)
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            _ = inet_pton(AF_INET6, address, &socketAddress.sin6_addr)
            result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw code == EADDRINUSE ? Failure.portInUse(port) : Failure.system("bind \(address)", code)
        }
        guard Glibc_or_Darwin_listen(fd, 16) == 0 else { let code = errno; close(fd); throw Failure.system("listen", code) }
        return fd
    }

    static func localPort(of fd: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        } == 0
        guard ok else { return 0 }
        let family = Int32(storage.ss_family)
        return withUnsafePointer(to: &storage) { pointer -> UInt16 in
            if family == AF_INET {
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
            return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
        }
    }
}
