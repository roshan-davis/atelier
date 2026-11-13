@testable import AgentMCP
import Foundation
import XCTest

final class AgentGrantTests: XCTestCase {
    func makeStore() -> AgentGrantStore {
        let suite = "agent-grants-\(UUID().uuidString)"
        return AgentGrantStore(defaults: UserDefaults(suiteName: suite)!, key: "grants")
    }

    func testRequestingMoreNeverRaisesTheGrant() {
        let grant = AgentGrant(clientID: "a#T", name: "Chat", profile: .organize)
        var client = AgentClient(id: "a#T", name: "Chat", pid: 1, requestedProfile: .everything)
        XCTAssertEqual(grant.authorization(for: client, appName: "Sketch"), .allowed(.organize))
        client.requestedProfile = .look
        XCTAssertEqual(grant.authorization(for: client, appName: "Sketch"), .allowed(.look))
        client.requestedProfile = nil
        XCTAssertEqual(grant.authorization(for: client, appName: "Sketch"), .allowed(.organize))
    }

    func testDeniedGrantSaysWhereToChangeIt() {
        let grant = AgentGrant(clientID: "a#T", name: "Chat", profile: nil)
        let client = AgentClient(id: "a#T", name: "Chat", pid: 1)
        guard case .denied(let reason) = grant.authorization(for: client, appName: "Sketch") else { return XCTFail() }
        XCTAssertTrue(reason.contains("Sketch > Settings… > Agents"))
    }

    func testStoreSavesReplacesTouchesAndRemoves() {
        let store = makeStore()
        XCTAssertNil(store.grant(for: "a#T"))
        store.save(AgentGrant(clientID: "a#T", name: "Chat", profile: .look, decidedAt: Date(timeIntervalSince1970: 10)))
        store.save(AgentGrant(clientID: "b#T", name: "Other", profile: nil, decidedAt: Date(timeIntervalSince1970: 20)))
        store.save(AgentGrant(clientID: "a#T", name: "Chat", profile: .edit, decidedAt: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(store.grant(for: "a#T")?.profile, .edit)
        XCTAssertEqual(store.all.map(\.clientID), ["b#T", "a#T"])
        store.touch(clientID: "a#T", at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(store.all.map(\.clientID), ["a#T", "b#T"])
        store.remove(clientID: "a#T")
        XCTAssertEqual(store.all.map(\.clientID), ["b#T"])
    }

    func testActivityLogKeepsNewestFirst() {
        var log = AgentActivityLog(capacity: 2)
        for name in ["one", "two", "three"] { log.add(AgentActivity(clientName: "Chat", kind: .call, text: name)) }
        XCTAssertEqual(log.entries.map(\.text), ["three", "two"])
    }
}
