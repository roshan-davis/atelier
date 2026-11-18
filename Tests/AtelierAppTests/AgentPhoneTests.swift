import AgentActions
import AgentMCP
import AtelierActions
import AtelierCore
import Foundation
import XCTest
@testable import AtelierApp

/// A paired phone over Streamable HTTP (AT-050f), end to end through Atelier's own host: read,
/// change and undo with a test client, and a phone call never raises a Mac Allow sheet. Uses the
/// HTTP endpoint without a socket, so nothing listens on this Mac while the tests run.
final class AgentPhoneTests: XCTestCase {
    @MainActor
    func testReadChangeAndUndoFromAPairedPhone() async throws {
        let (library, ids) = try await makeLibrary(["landscape"])
        let (endpoint, token) = try await pairedEndpoint(library)
        let session = try await initialize(endpoint, token)

        let tools = try await rpc(endpoint, token, session, "tools/list", [:])
        let names = tools["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        for name in ["get_context", "search_photos", "get_photo", "set_metadata", "undo_change", "adjust"] {
            XCTAssertTrue(names.contains(name), "\(name) missing from \(names)")
        }
        // Docking stays the Mac Docent's job: no docking over HTTP.
        let docking = await post(endpoint, token, session,
                                 #"{"jsonrpc":"2.0","id":9,"method":"\#(DockingProtocol.dock)","params":{}}"#)
        XCTAssertEqual(JSONValue(parsing: docking.body)?["error"]?["code"], .int(-32601))

        let found = try await call(endpoint, token, session, "search_photos", [:])
        XCTAssertEqual(found["total"], .int(1))
        let photo = try XCTUnwrap(found["photos"]?.arrayValue?.first)
        // "label" appears only when the photo has a color label, as over the helper.
        for key in ["id", "filename", "rating", "flag"] { XCTAssertNotNil(photo[key], key) }

        let changed = try await call(endpoint, token, session, "set_metadata",
                                     ["ids": .array([.int(Int(ids[0]))]), "rating": .int(4)])
        let change = try XCTUnwrap(changed["change"]?.stringValue)
        for key in ["did", "photos", "ids", "undo"] { XCTAssertNotNil(changed[key], key) }
        let rated = try await call(endpoint, token, session, "get_photo", ["id": .int(Int(ids[0]))])
        XCTAssertEqual(rated["rating"], .int(4))
        // The activity log names the phone.
        XCTAssertTrue(library.agents.activity.entries.contains { $0.clientName == "Docent on iPhoneRo" })

        _ = try await call(endpoint, token, session, "undo_change", ["change": .string(change)])
        let undone = try await call(endpoint, token, session, "get_photo", ["id": .int(Int(ids[0]))])
        XCTAssertEqual(undone["rating"], .int(0))
    }

    /// Above Settings > Agents' limit a Mac client gets the Allow sheet; a phone never does: it
    /// fails at once with This app asks for me off, and runs on the phone's own Allow with it.
    @MainActor
    func testAPhoneCallNeverRaisesAMacAllowSheet() async throws {
        let saved = UserDefaults.standard.object(forKey: AgentSettings.confirmAboveKey)
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: AgentSettings.confirmAboveKey) }
        UserDefaults.standard.set(1, forKey: AgentSettings.confirmAboveKey)
        let (library, ids) = try await makeLibrary(["landscape", "portrait"])
        let (endpoint, token) = try await pairedEndpoint(library)
        let session = try await initialize(endpoint, token)
        let device = try XCTUnwrap(library.agents.phone.store.devices.first)
        XCTAssertTrue(device.asksForMe, "a new phone asks for itself")
        library.agents.phone.setAsksForMe(false, for: device.id)
        let arguments: [String: JSONValue] = ["ids": .array(ids.map { .int(Int($0)) }), "flag": .string("picked")]

        let started = Date()
        let refused = try await callResult(endpoint, token, session, "set_metadata", arguments)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a phone call must never wait for the Mac")
        XCTAssertEqual(refused["isError"], .bool(true))
        let message = refused["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("Allow Docent on iPhoneRo to ask for you in Atelier > Settings… > Agents"), message)

        library.agents.phone.setAsksForMe(true, for: device.id)
        let allowed = try await call(endpoint, token, session, "set_metadata", arguments)
        XCTAssertEqual(allowed["photos"], .int(2))
    }

    @MainActor
    func testRevokedPhoneIsTold() async throws {
        let (library, _) = try await makeLibrary(["landscape"])
        let (endpoint, token) = try await pairedEndpoint(library)
        let session = try await initialize(endpoint, token)
        let device = try XCTUnwrap(library.agents.phone.store.devices.first)
        library.agents.phone.revoke(device.id)
        let reply = await post(endpoint, token, session, #"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#)
        XCTAssertEqual(reply.status, 401)
        XCTAssertEqual(JSONValue(parsing: reply.body)?["error"]?["message"], .string("revoked"))
    }

    func testPairingProfileFollowsDocentOnTheMac() {
        let store = AgentGrantStore(defaults: UserDefaults(suiteName: "grants-\(UUID().uuidString)")!, key: "g")
        XCTAssertEqual(AgentPhone.pairingProfile(store), .edit)
        store.save(AgentGrant(clientID: "app.docent#T", name: "Docent", profile: .organize))
        XCTAssertEqual(AgentPhone.pairingProfile(store), .organize)
    }

    // MARK: Helpers

    @MainActor
    private func pairedEndpoint(_ library: LibraryModel) async throws -> (MCPHTTPEndpoint, String) {
        let agents = library.agents
        let store = agents.phone.store
        // The test process's own defaults: start with no phones and leave none behind.
        for device in store.devices { store.revoke(id: device.id) }
        addTeardownBlock { @MainActor in for device in store.devices { store.revoke(id: device.id) } }
        let host = AtelierMCPHost(server: agents, tools: AgentLookTools(catalog: library.catalog, previews: library.previews),
                                  docking: agents.dock.coordinator)
        let endpoint = MCPHTTPEndpoint(host: host, devices: store, pairingProfile: { .edit })
        let code = store.startPairing()
        return (endpoint, code.token)
    }

    private func initialize(_ endpoint: MCPHTTPEndpoint, _ token: String) async throws -> String {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Docent on iPhoneRo","version":"1"}}}"#
        let reply = await post(endpoint, token, nil, body)
        XCTAssertEqual(reply.status, 200, String(decoding: reply.body, as: UTF8.self))
        return try XCTUnwrap(reply.headers[MCPHTTPEndpoint.sessionHeader])
    }

    private func post(_ endpoint: MCPHTTPEndpoint, _ token: String, _ session: String?, _ body: String) async -> HTTPResponse {
        var headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
        if let session { headers[MCPHTTPEndpoint.sessionHeader] = session }
        return await endpoint.respond(to: HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(body.utf8)))
    }

    private func rpc(_ endpoint: MCPHTTPEndpoint, _ token: String, _ session: String, _ method: String,
                     _ params: [String: JSONValue]) async throws -> JSONValue {
        let body = JSONValue.object(["jsonrpc": .string("2.0"), "id": .int(2), "method": .string(method),
                                     "params": .object(params)]).compactText
        let reply = await post(endpoint, token, session, body)
        XCTAssertEqual(reply.status, 200)
        return try XCTUnwrap(JSONValue(parsing: reply.body)?["result"], String(decoding: reply.body, as: UTF8.self))
    }

    private func callResult(_ endpoint: MCPHTTPEndpoint, _ token: String, _ session: String, _ tool: String,
                            _ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await rpc(endpoint, token, session, "tools/call", ["name": .string(tool), "arguments": .object(arguments)])
    }

    private func call(_ endpoint: MCPHTTPEndpoint, _ token: String, _ session: String, _ tool: String,
                      _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let result = try await callResult(endpoint, token, session, tool, arguments)
        XCTAssertEqual(result["isError"], .bool(false), result.compactText)
        return try XCTUnwrap(result["structuredContent"], result.compactText)
    }

    @MainActor
    private func makeLibrary(_ fixtures: [String]) async throws -> (LibraryModel, [Int64]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/presets/fixtures")
        let catalog = try Catalog(packageURL: folder.appendingPathComponent("AgentPhone.atelier"))
        var ids: [Int64] = []
        for fixture in fixtures {
            let copy = folder.appendingPathComponent(fixture + ".jpg")
            try FileManager.default.copyItem(at: directory.appendingPathComponent(fixture + ".jpg"), to: copy)
            let imported = await Importer(catalog: catalog, previews: nil).run(sources: [copy],
                                                                               options: ImportOptions(buildPreviews: false))
            ids.append(try XCTUnwrap(imported.importedAssetIDs.first))
        }
        return (LibraryModel(catalog: catalog), ids)
    }
}
