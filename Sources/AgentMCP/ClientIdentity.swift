import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(Security)
import Security
#endif

/// Works out who launched a helper, from its process id: the app it runs under (Claude, Cherry
/// Studio, LM Studio) or Terminal for command-line clients. Grants use this checked name, so a
/// client can't pass itself off as another by what it says or by the helper's arguments.
public enum ClientIdentity {
    public static func client(forHelper pid: Int32) -> AgentClient {
        guard let launcher = launchingApp(of: pid) else {
            let path = executablePath(of: parent(of: pid) ?? pid)
            let name = path.map { ($0 as NSString).lastPathComponent } ?? "Unknown app"
            return AgentClient(id: "process#\(name)", name: name, path: path, pid: pid)
        }
        return AgentClient(id: launcher.id, name: launcher.name, path: launcher.path, pid: pid)
    }

    struct Launcher {
        var id: String
        var name: String
        var path: String
    }

    /// The outermost `.app` among the helper's ancestors (Claude's helper processes live inside
    /// Claude.app, so the outer bundle is the one that counts).
    static func launchingApp(of pid: Int32) -> Launcher? {
        var current: Int32? = parent(of: pid)
        var visited = 0
        while let process = current, process > 1, visited < 32 {
            visited += 1
            if let path = executablePath(of: process), let bundle = outerBundle(in: path) {
                return launcher(at: bundle)
            }
            current = parent(of: process)
        }
        return nil
    }

    static func outerBundle(in executable: String) -> String? {
        guard let range = executable.range(of: ".app/") else { return nil }
        return String(executable[executable.startIndex..<range.lowerBound]) + ".app"
    }

    static func launcher(at bundlePath: String) -> Launcher {
        let url = URL(fileURLWithPath: bundlePath)
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier ?? url.lastPathComponent
        return Launcher(id: "\(bundleID)#\(signingTeam(of: url) ?? "unsigned")", name: name, path: bundlePath)
    }

    /// The Team ID of a validly signed bundle; "apple" for Apple's own apps; nil when unsigned
    /// or the signature doesn't check out.
    static func signingTeam(of url: URL) -> String? {
        #if canImport(Security) && os(macOS)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String { return team }
        // Apple's apps (Terminal) carry no Team ID; their identifier is enough.
        if let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String, identifier.hasPrefix("com.apple.") {
            return "apple"
        }
        return nil
        #else
        return nil
        #endif
    }

    static func parent(of pid: Int32) -> Int32? {
        #if os(macOS)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
        #elseif os(Linux)
        guard let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8) else { return nil }
        for line in status.split(separator: "\n") where line.hasPrefix("PPid:") {
            return Int32(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
        }
        return nil
        #else
        return nil
        #endif
    }

    static func executablePath(of pid: Int32) -> String? {
        #if os(macOS)
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
        #elseif os(Linux)
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
        #else
        return nil
        #endif
    }
}
