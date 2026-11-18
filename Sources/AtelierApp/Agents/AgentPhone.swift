import AgentActions
import AgentMCP
import AppKit
import Foundation
import Network

/// Settings > Agents > Phone, as user defaults.
enum PhoneSettings {
    static let enabledKey = "agents.phone.enabled"
    static let portKey = "agents.phone.port"
    /// Atelier's fixed port (Easel uses 47802), editable in the pane.
    static let defaultPort = 47801

    /// Off unless turned on.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var port: UInt16 {
        let stored = UserDefaults.standard.object(forKey: portKey) as? Int ?? defaultPort
        return UInt16(clamping: (1024...65535).contains(stored) ? stored : defaultPort)
    }
}

/// Paired phones (AT-050f): Atelier's MCP over Streamable HTTP at `/mcp`, on 127.0.0.1 and the
/// Mac's Tailscale address only, behind a per-device token paired with a QR code. Off by
/// default; with no Tailscale address the listener stays off; it follows the address as
/// interfaces change. Same tools, results and views as the local helper.
@MainActor
final class AgentPhone: ObservableObject {
    enum Status: Equatable {
        case off
        /// Agents are turned off (Settings > Agents > Allow chat apps).
        case agentsOff
        case noTailscale
        case listening(addresses: [String], port: UInt16)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var devices: [PairedDevice] = []
    /// The code on screen in Pair a Phone…, until it is used, cancelled or expires.
    @Published private(set) var pairing: PairingCode?
    /// The MagicDNS name of this Mac (`roshs-mac.tail1234.ts.net`), once looked up.
    @Published private(set) var hostName: String?
    /// The name of the phone that just paired, for the pairing sheet's last word.
    @Published private(set) var justPaired: String?

    let store = PhoneDeviceStore()
    private weak var server: AgentServer?
    private var listener: MCPHTTPServer?
    private var monitor: NWPathMonitor?
    private var recheck: Timer?

    init(server: AgentServer) {
        self.server = server
        devices = store.devices
    }

    var isEnabled: Bool { PhoneSettings.isEnabled }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PhoneSettings.enabledKey)
        refresh()
    }

    func setPort(_ port: Int) {
        guard (1024...65535).contains(port), port != Int(PhoneSettings.port) else { return }
        UserDefaults.standard.set(port, forKey: PhoneSettings.portKey)
        stopListening()
        refresh()
    }

    // MARK: Listening

    /// Starts, moves or stops the listener to match the settings and the Mac's tailnet address.
    func refresh() {
        guard isEnabled else {
            stopWatching()
            stopListening()
            status = .off
            return
        }
        startWatching()
        guard let server, server.isRunning, let host = server.host else {
            stopListening()
            status = .agentsOff
            return
        }
        let addresses = TailnetAddresses.bindAddresses(from: TailnetAddresses.currentInterfaces())
        guard !addresses.isEmpty else {
            stopListening()
            status = .noTailscale
            return
        }
        let port = PhoneSettings.port
        if let listener, listener.isRunning, listener.boundAddresses == addresses, listener.port == port { return }
        stopListening()
        let endpoint = MCPHTTPEndpoint(host: host, devices: store, pairingProfile: { [grants = server.grants] in
            AgentPhone.pairingProfile(grants)
        })
        endpoint.onPaired = { [weak self] device in
            Task { @MainActor in self?.paired(device) }
        }
        let http = MCPHTTPServer(endpoint: endpoint)
        do {
            try http.start(addresses: addresses, port: port)
            listener = http
            status = .listening(addresses: addresses, port: port)
            lookUpHostName(addresses)
        } catch {
            status = .failed("Couldn't listen for phones: \(error).")
        }
    }

    private func stopListening() {
        listener?.stop()
        listener = nil
    }

    /// Interfaces change (Tailscale connects, the address moves, Wi-Fi drops): look again. The
    /// timer is a backstop for changes the path monitor doesn't report.
    private func startWatching() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        monitor.start(queue: DispatchQueue(label: "Atelier phone interfaces", qos: .utility))
        self.monitor = monitor
        recheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopWatching() {
        monitor?.cancel()
        monitor = nil
        recheck?.invalidate()
        recheck = nil
    }

    private func lookUpHostName(_ addresses: [String]) {
        guard let address = TailnetAddresses.preferredTailnetAddress(addresses) else { return }
        Task.detached(priority: .utility) {
            let name = TailnetAddresses.magicDNSName(for: address) ?? AgentPhone.tailscaleCLIName()
            await MainActor.run { [weak self] in self?.hostName = name }
        }
    }

    /// The name from Tailscale's own command-line tool, when the reverse lookup found none.
    nonisolated static func tailscaleCLIName() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale",
                          "/opt/homebrew/bin/tailscale"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--self", "--peers=false", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let name = JSONValue(parsing: data)?["Self"]?["DNSName"]?.stringValue, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// Where the phone connects: the MagicDNS name, else the tailnet IP.
    var pairingURL: String? {
        guard case .listening(let addresses, let port) = status,
              let host = hostName ?? TailnetAddresses.preferredTailnetAddress(addresses) else { return nil }
        return PairingCode.url(host: host, port: port)
    }

    // MARK: Pairing

    /// Pair a Phone…: a fresh code for 5 minutes, replacing any code on screen.
    func startPairing() {
        justPaired = nil
        pairing = store.startPairing()
    }

    func cancelPairing() {
        store.cancelPairing()
        pairing = nil
    }

    /// The QR code's text.
    func pairingPayload(_ code: PairingCode) -> String? {
        pairingURL.map { code.payload(app: AgentServer.appName, url: $0) }
    }

    private func paired(_ device: PairedDevice) {
        pairing = nil
        justPaired = device.name
        devices = store.devices
        server?.log(device.name, .allowed, "Paired as \(device.profile.title)")
    }

    /// A new phone gets the rights Docent has on the Mac, or Edit when Docent hasn't connected
    /// here (Docent asks on its own card before every change).
    nonisolated static func pairingProfile(_ grants: AgentGrantStore) -> AgentProfile {
        grants.all.first { $0.name.localizedCaseInsensitiveContains("Docent") && $0.profile != nil }?.profile ?? .edit
    }

    // MARK: Devices

    func revoke(_ id: String) {
        guard let device = store.revoke(id: id) else { return }
        listener?.endpoint.dropSessions(deviceID: id)
        devices = store.devices
        DeleteFeedback.play(.remove)
        server?.log(device.name, .denied, "Revoked")
    }

    func setProfile(_ profile: AgentProfile, for id: String) {
        store.update(id: id) { $0.profile = profile }
        // Its sessions end, so the phone lists the tools again under the new profile.
        listener?.endpoint.dropSessions(deviceID: id)
        devices = store.devices
        if let device = store.device(id: id) { server?.log(device.name, .allowed, "Allowed as \(profile.title)") }
    }

    func setAsksForMe(_ on: Bool, for id: String) {
        store.update(id: id) { $0.asksForMe = on }
        devices = store.devices
    }

    /// Refreshes Last used (Settings shows the list while open).
    func reloadDevices() { devices = store.devices }

    // MARK: Host

    func authorization(for client: AgentClient) -> AgentAuthorization {
        guard let id = PairedDevice.deviceID(fromClientID: client.id), let device = store.device(id: id) else {
            return .denied("This phone isn't paired with \(AgentServer.appName) any more. Pair it again in "
                           + "\(AgentServer.appName) > Settings… > Agents > Phone.")
        }
        return .allowed(device.profile)
    }

    /// Whether the phone's own Allow card is the only approval ("This app asks for me").
    func asksForMe(_ client: AgentClient) -> Bool {
        guard let id = PairedDevice.deviceID(fromClientID: client.id) else { return false }
        return store.device(id: id)?.asksForMe ?? false
    }

    /// What a phone hears when a call needs an Allow at the Mac and it may not give one itself.
    static func needsAllowAtMac(_ client: AgentClient) -> String {
        "Nothing was changed: this needs an Allow, and nobody may be at the Mac. Allow \(client.name) to ask for you in "
            + "\(AgentServer.appName) > Settings… > Agents > Phone (This app asks for me)."
    }
}
