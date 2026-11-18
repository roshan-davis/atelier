import AgentActions
import Foundation

/// A phone paired with the app over the tailnet (AT-050f; the shared contract in
/// Docs/Atelier-Agent-Actions.md, "From a phone"). Its own grant: the profile it may use and
/// whether its own Allow card is the only approval ("This app asks for me").
public struct PairedDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// From the pairing `initialize`'s `clientInfo`: "Docent on iPhoneRo".
    public var name: String
    /// SHA-256 of the device's token (TokenHash); the token itself is never kept.
    public var tokenHash: String
    public var pairedAt: Date
    public var lastUsed: Date?
    public var profile: AgentProfile
    /// The phone's own Allow card is the only approval: the app never asks at the Mac for it.
    /// Off: a call that would need the Mac's Allow fails at once. On for a new phone (as Easel):
    /// Docent shows its own Allow card, and nobody may be at the Mac.
    public var asksForMe: Bool

    public init(id: String = UUID().uuidString, name: String, tokenHash: String, pairedAt: Date = Date(),
                lastUsed: Date? = nil, profile: AgentProfile, asksForMe: Bool = true) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.lastUsed = lastUsed
        self.profile = profile
        self.asksForMe = asksForMe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tokenHash = try container.decode(String.self, forKey: .tokenHash)
        pairedAt = try container.decode(Date.self, forKey: .pairedAt)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        profile = try container.decodeIfPresent(AgentProfile.self, forKey: .profile) ?? .look
        asksForMe = try container.decodeIfPresent(Bool.self, forKey: .asksForMe) ?? true
    }

    static let clientPrefix = "phone#"

    /// The id its sessions carry as `AgentClient.id`.
    public var clientID: String { Self.clientPrefix + id }

    /// The device id inside a phone client's id, or nil for a client on the Mac.
    public static func deviceID(fromClientID clientID: String) -> String? {
        clientID.hasPrefix(clientPrefix) ? String(clientID.dropFirst(clientPrefix.count)) : nil
    }

    /// The client its sessions run as.
    public var client: AgentClient {
        AgentClient(id: clientID, name: name, pid: 0, clientInfo: name, isRemote: true)
    }

    /// A readable name from `clientInfo.name`: trimmed, at most 80 characters (as Easel).
    public static func name(fromClientInfo raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? "Phone" : String(trimmed.prefix(80))
    }
}

/// The code Pair a Phone… shows as a QR code: a fresh token that pairs the first device whose
/// `initialize` brings it before it expires.
public struct PairingCode: Sendable, Hashable {
    public static let lifetime: TimeInterval = 5 * 60

    public let token: String
    public let expires: Date

    public init(token: String = TokenHash.newToken(), expires: Date) {
        self.token = token
        self.expires = expires
    }

    /// The QR payload, version 1: `{"v":1,"app":"Atelier","url":"http://<host>:47801/mcp","token":"…","expires":"…"}`.
    public func payload(app: String, url: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let value = JSONValue.object(["v": .int(1), "app": .string(app), "url": .string(url), "token": .string(token),
                                      "expires": .string(formatter.string(from: expires))])
        return value.compactText
    }

    /// `http://<host>:<port>/mcp`, with an IPv6 address in brackets.
    public static func url(host: String, port: UInt16) -> String {
        let shown = host.contains(":") ? "[\(host)]" : host
        return "http://\(shown):\(port)\(MCPHTTPEndpoint.path)"
    }
}

/// What a bearer token is.
public enum PhoneCredential: Equatable, Sendable {
    case device(PairedDevice)
    /// The code on the Mac's screen, still unused and in time.
    case pairing
    /// A device the person revoked: the phone is told so ("revoked").
    case revoked
    case unknown
}

/// Paired devices, kept in user defaults as hashes only, and the one pairing code on screen
/// (memory only: quitting the app ends it).
public final class PhoneDeviceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var pending: PairingCode?
    /// How many revoked tokens are remembered, so their phones hear "revoked" rather than nothing.
    static let revokedMemory = 50
    /// `lastUsed` is written at most this often per device.
    static let touchInterval: TimeInterval = 60

    public init(defaults: UserDefaults = .standard, key: String = "agents.phones") {
        self.defaults = defaults
        self.key = key
    }

    /// Paired devices, most recently paired first.
    public var devices: [PairedDevice] {
        lock.withLock { load().devices }.sorted { $0.pairedAt > $1.pairedAt }
    }

    public func device(id: String) -> PairedDevice? {
        lock.withLock { load().devices.first { $0.id == id } }
    }

    // MARK: Pairing

    /// A new code, replacing any code still on screen.
    public func startPairing(now: Date = Date()) -> PairingCode {
        let code = PairingCode(expires: now.addingTimeInterval(PairingCode.lifetime))
        lock.withLock { pending = code }
        return code
    }

    public func cancelPairing() { lock.withLock { pending = nil } }

    /// The code on screen, while it is in time.
    public func pendingPairing(now: Date = Date()) -> PairingCode? {
        lock.withLock { pending.flatMap { $0.expires > now ? $0 : nil } }
    }

    /// Pairs the device whose first `initialize` brought the code: the token becomes its
    /// credential. A device of the same name (the same phone paired again) is replaced, so its
    /// old token stops working. Nil when the code doesn't match or has expired.
    public func completePairing(token: String, clientName: String?, profile: AgentProfile,
                                now: Date = Date()) -> PairedDevice? {
        lock.withLock {
            guard let code = pending, code.expires > now,
                  TokenHash.equal(TokenHash.hash(code.token), TokenHash.hash(token)) else { return nil }
            pending = nil
            var state = load()
            let name = PairedDevice.name(fromClientInfo: clientName)
            var device = PairedDevice(name: name, tokenHash: TokenHash.hash(token), pairedAt: now, lastUsed: now, profile: profile)
            if let old = state.devices.first(where: { $0.name == name }) {
                // The same phone again: same grant, new token.
                device.id = old.id
                device.profile = old.profile
                device.asksForMe = old.asksForMe
                state.devices.removeAll { $0.id == old.id }
            }
            state.devices.append(device)
            store(state)
            return device
        }
    }

    // MARK: Checking

    public func check(token: String, now: Date = Date()) -> PhoneCredential {
        let hash = TokenHash.hash(token)
        return lock.withLock {
            let state = load()
            // Every stored hash is compared, so the time taken doesn't say which one matched.
            var found: PairedDevice?
            for device in state.devices where TokenHash.equal(device.tokenHash, hash) { found = device }
            if let found { return .device(found) }
            var revoked = false
            for old in state.revoked where TokenHash.equal(old, hash) { revoked = true }
            if revoked { return .revoked }
            if let code = pending, code.expires > now, TokenHash.equal(TokenHash.hash(code.token), hash) { return .pairing }
            return .unknown
        }
    }

    // MARK: Changing

    /// Removes the device; its token answers "revoked" from now on.
    @discardableResult
    public func revoke(id: String) -> PairedDevice? {
        lock.withLock {
            var state = load()
            guard let device = state.devices.first(where: { $0.id == id }) else { return nil }
            state.devices.removeAll { $0.id == id }
            state.revoked.insert(device.tokenHash, at: 0)
            if state.revoked.count > Self.revokedMemory { state.revoked.removeLast(state.revoked.count - Self.revokedMemory) }
            store(state)
            return device
        }
    }

    /// Changes a device's grant (profile, "This app asks for me").
    public func update(id: String, _ change: (inout PairedDevice) -> Void) {
        lock.withLock {
            var state = load()
            guard let index = state.devices.firstIndex(where: { $0.id == id }) else { return }
            change(&state.devices[index])
            store(state)
        }
    }

    /// Records a call, for Last used (written at most once a minute per device).
    public func touch(id: String, now: Date = Date()) {
        lock.withLock {
            var state = load()
            guard let index = state.devices.firstIndex(where: { $0.id == id }) else { return }
            if let last = state.devices[index].lastUsed, now.timeIntervalSince(last) < Self.touchInterval { return }
            state.devices[index].lastUsed = now
            store(state)
        }
    }

    // MARK: Storage

    struct State: Codable {
        var devices: [PairedDevice] = []
        var revoked: [String] = []
    }

    private func load() -> State {
        guard let data = defaults.data(forKey: key) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    private func store(_ state: State) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(state) { defaults.set(data, forKey: key) }
    }
}
