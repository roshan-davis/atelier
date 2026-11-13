import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A private Unix domain socket: only the current user can connect (the socket file is 0600 in
/// a 0700 folder, and each peer's user id is checked). Lines in, lines out.
enum UnixSocket {
    enum Failure: Error, CustomStringConvertible {
        case system(String, Int32)
        case pathTooLong(String)
        var description: String {
            switch self {
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            case .pathTooLong(let path): return "Socket path too long: \(path)"
            }
        }
    }

    static func makeSocket() throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        #if canImport(Darwin)
        // Writing to a closed peer must return an error, not kill the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    /// Opens a listening socket at `path`, replacing a stale one.
    static func listen(at path: String) throws -> Int32 {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        unlink(path)
        let fd = try makeSocket()
        var address = try address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let code = errno; close(fd); throw Failure.system("bind", code) }
        chmod(path, 0o600)
        guard Glibc_or_Darwin_listen(fd, 8) == 0 else { let code = errno; close(fd); throw Failure.system("listen", code) }
        return fd
    }

    static func connect(to path: String) throws -> Int32 {
        let fd = try makeSocket()
        var address = try address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc_or_Darwin_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let code = errno; close(fd); throw Failure.system("connect", code) }
        return fd
    }

    /// Waits up to `timeout` seconds for `fd` to be readable.
    static func waitReadable(_ fd: Int32, timeout: Double) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, Int32(timeout * 1000)) > 0
    }

    /// The peer's process id and user id.
    static func peer(of fd: Int32) -> (pid: Int32, uid: uid_t)? {
        #if os(Linux)
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; } (Glibc hides it without _GNU_SOURCE).
        struct PeerCredentials { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
        var credentials = PeerCredentials()
        var length = socklen_t(MemoryLayout<PeerCredentials>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 else { return nil }
        return (credentials.pid, credentials.uid)
        #else
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL (0), LOCAL_PEERPID (2), from <sys/un.h>.
        guard getsockopt(fd, 0, 2, &pid, &length) == 0 else { return nil }
        return (pid, uid)
        #endif
    }

    /// Writes all of `data`; false when the peer is gone.
    static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                #if os(Linux)
                let sent = send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))
                #else
                let sent = send(fd, pointer, remaining, 0)
                #endif
                if sent < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= sent
                pointer += sent
            }
            return true
        }
    }
}

/// Splits a byte stream into lines (MCP stdio messages end with \n).
struct LineReader {
    private var buffer = Data()
    /// The longest message accepted (a guard against a runaway peer).
    static let limit = 16 * 1024 * 1024

    /// Adds bytes and returns the complete lines they finish; nil when a line is too long.
    mutating func add(_ bytes: Data) -> [Data]? {
        buffer.append(bytes)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return buffer.count > Self.limit ? nil : lines
    }

    /// Reads once from `fd`: the lines it completes, or nil at end of stream or error.
    mutating func read(from fd: Int32) -> [Data]? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Glibc_or_Darwin_read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            return add(Data(chunk[0..<count]))
        }
    }
}

// The C calls whose Swift names clash with UnixSocket's own methods.
@inline(__always) func Glibc_or_Darwin_listen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
@inline(__always) func Glibc_or_Darwin_connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(fd, address, length)
}
@inline(__always) func Glibc_or_Darwin_read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(fd, buffer, count)
}
