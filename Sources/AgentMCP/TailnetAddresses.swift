import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where the phone listener may listen (AT-050f): 127.0.0.1 and the Mac's Tailscale addresses
/// (100.64.0.0/10, fd7a:115c:a1e0::/48), never 0.0.0.0 and never the Wi-Fi or Ethernet address,
/// because plain HTTP there would send the token in the clear on a shared network.
public enum TailnetAddresses {
    public static let loopback = "127.0.0.1"

    /// One address on one interface.
    public struct Interface: Hashable, Sendable {
        public var name: String
        public var address: String
        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    /// A Tailscale (CGNAT 100.64.0.0/10 or Tailscale's ULA fd7a:115c:a1e0::/48) address.
    public static func isTailnet(_ address: String) -> Bool {
        if let bytes = ipv4(address) { return bytes[0] == 100 && (bytes[1] & 0xC0) == 64 }
        if let bytes = ipv6(address) { return bytes[0] == 0xFD && bytes[1] == 0x7A && bytes[2] == 0x11 && bytes[3] == 0x5C
            && bytes[4] == 0xA1 && bytes[5] == 0xE0 }
        return false
    }

    /// The only addresses the listener will bind.
    public static func isAllowedBindAddress(_ address: String) -> Bool {
        address == loopback || isTailnet(address)
    }

    /// The addresses to listen on now: none without a tailnet address (the listener stays off),
    /// otherwise 127.0.0.1 and the tailnet addresses, IPv4 first.
    public static func bindAddresses(from interfaces: [Interface]) -> [String] {
        var tailnet: [String] = []
        for interface in interfaces where isTailnet(interface.address) && !tailnet.contains(interface.address) {
            tailnet.append(interface.address)
        }
        guard !tailnet.isEmpty else { return [] }
        tailnet.sort { (ipv4($0) != nil ? 0 : 1, $0) < (ipv4($1) != nil ? 0 : 1, $1) }
        return [loopback] + tailnet
    }

    /// The tailnet address the QR code names when there is no MagicDNS name: IPv4 when there is one.
    public static func preferredTailnetAddress(_ addresses: [String]) -> String? {
        addresses.first { isTailnet($0) && ipv4($0) != nil } ?? addresses.first(where: isTailnet)
    }

    /// Every interface address on this machine.
    public static func currentInterfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var interfaces: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // A link-local IPv6 address carries its scope ("fe80::1%en0"); none of those are bound.
            interfaces.append(Interface(name: String(cString: entry.pointee.ifa_name), address: text))
        }
        return interfaces
    }

    /// The Mac's MagicDNS name for a tailnet address (reverse lookup through Tailscale's resolver),
    /// such as `roshs-mac.tail1234.ts.net`, or nil. Blocking: call it off the main thread.
    public static func magicDNSName(for address: String) -> String? {
        guard let bytes = ipv4(address) else { return nil }
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        #if canImport(Darwin)
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        withUnsafeMutableBytes(of: &socketAddress.sin_addr) { $0.copyBytes(from: bytes) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        var name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty || ipv4(name) != nil ? nil : name
    }

    // MARK: Parsing

    static func ipv4(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func ipv6(_ text: String) -> [UInt8]? {
        guard !text.contains("%") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}
