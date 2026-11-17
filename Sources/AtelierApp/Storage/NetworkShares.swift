import AppKit
import AtelierCore
import Foundation
import NetFS
import Network

/// Connecting and disconnecting network shares for storage locations (AT-079a). macOS does the
/// work: NetFS mounts the share and shows its own sign-in sheet when the Keychain has no password
/// (the same Keychain item Finder saves with "Remember this password"), so Atelier never asks for
/// or stores a password itself.
enum NetworkShares {
    enum ConnectError: LocalizedError {
        case badAddress(String)
        case failed(String, Int32)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .badAddress(let text): return "“\(text)” isn't a server address. Try smb://server/share."
            case .failed(let server, let code):
                return "Couldn't connect to \(server) (\(code)). Check that it is on and on the same network."
            case .cancelled: return "Connecting was cancelled."
            }
        }
    }

    /// Mounts `address` ("smb://megham.local/Photos", or a server alone, where macOS then asks which
    /// share). `allowUI` false connects silently with the Keychain's password, for "Connect when
    /// Atelier opens". Runs off the main thread; the completion comes back on the main thread with
    /// the mounted volume roots.
    static func connect(_ address: String, allowUI: Bool,
                        completion: @escaping @MainActor @Sendable (Result<[URL], ConnectError>) -> Void) {
        guard let normalized = ServerAddress.normalized(address), let url = URL(string: normalized) else {
            completion(.failure(.badAddress(address)))
            return
        }
        let server = url.host ?? address
        let openOptions = NSMutableDictionary()
        // kNAUIOptionKey / kNAUIOptionAllowUI / kNAUIOptionNoUI.
        openOptions["UIOption"] = allowUI ? "AllowUI" : "NoUI"
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions as CFMutableDictionary, nil, &request,
                                        DispatchQueue.main) { status, _, mountpoints in
            let paths = (mountpoints as? [String]) ?? []
            MainActor.assumeIsolated {
                switch status {
                case 0: completion(.success(paths.map { URL(fileURLWithPath: $0, isDirectory: true) }))
                case Int32(ECANCELED), -128: completion(.failure(.cancelled))
                default: completion(.failure(.failed(server, status)))
                }
            }
        }
        if status != 0 {
            completion(.failure(.failed(server, status)))
        }
    }

    /// Unmounts the share (Disconnect). Off the main thread: an unresponsive server can take a while.
    static func disconnect(_ root: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        Task.detached(priority: .userInitiated) {
            var failure: Error?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: root) } catch { failure = error }
            let result = failure
            await MainActor.run { completion(result) }
        }
    }
}

/// Servers offering SMB on this network, found by Bonjour, for Add Location's server list.
/// Runs only while Add Location shows them.
@MainActor
final class ShareBrowser: ObservableObject {
    struct Server: Identifiable, Hashable {
        var name: String
        var id: String { name }
        /// "smb://megham.local"
        var address: String {
            let host = name.replacingOccurrences(of: " ", with: "-")
            return "smb://\(host).local"
        }
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var isSearching = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in
                self?.servers = Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .map(Server.init(name:))
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let searching: Bool
            switch state {
            case .ready, .setup: searching = true
            default: searching = false
            }
            Task { @MainActor in self?.isSearching = searching }
        }
        self.browser = browser
        browser.start(queue: .global(qos: .utility))
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}
