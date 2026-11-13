import AgentActions
import AtelierActions
import Foundation
import XCTest

/// Atelier's catalog: valid, complete, committed, and the only way menus are built.
final class AtelierActionsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalogFile = root.appendingPathComponent("Docs/agent-actions-catalog.json")

    func testCatalogHasNoProblems() {
        XCTAssertEqual(AtelierAction.catalog.problems, [])
    }

    /// Every `static let … = Action<…>` declared in AtelierActions.swift is in `all`.
    func testEveryDeclaredActionIsListed() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/AtelierActions/AtelierActions.swift"),
                                encoding: .utf8)
        let declared = source.components(separatedBy: "\n").filter { $0.contains("public static let ") && $0.contains(" = Action<") }
        XCTAssertGreaterThan(declared.count, 0)
        XCTAssertEqual(declared.count, AtelierAction.all.count,
                       "Add every action declared in AtelierActions.swift to AtelierAction.all")
    }

    func testDeletesAreNeverExposed() {
        for action in AtelierAction.all where action.kind == .deletes {
            XCTAssertFalse(action.isExposed, action.id.rawValue)
        }
    }

    /// Docs/agent-actions-catalog.json is current. Regenerate it with
    /// `python3 Scripts/agent_catalog.py` (or ATELIER_WRITE_AGENT_CATALOG=1 swift test --filter AtelierActionsTests).
    func testCommittedCatalogIsCurrent() throws {
        let text = AtelierAction.catalog.json.text
        if ProcessInfo.processInfo.environment["ATELIER_WRITE_AGENT_CATALOG"] == "1" {
            try Data(text.utf8).write(to: Self.catalogFile)
            return
        }
        let committed = try? String(contentsOf: Self.catalogFile, encoding: .utf8)
        XCTAssertEqual(committed, text,
                       "Docs/agent-actions-catalog.json is stale. Run python3 Scripts/agent_catalog.py and commit it.")
    }

    /// Menu items, key commands and right-click items come only from registry actions: these
    /// files may not make a bare Button, Toggle or menu item. A line that truly isn't a command
    /// says why with `// not an action: <reason>`.
    func testMenusAreBuiltOnlyFromActions() throws {
        let files = ["Sources/AtelierApp/AtelierApp.swift", "Sources/AtelierApp/PhotoMenu.swift"]
        let banned = ["Button(", "Toggle(", "ClosureMenuItem(", "NSMenuItem(title:"]
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !line.contains("// not an action:") else { continue }
                if banned.contains(where: { line.contains($0) }) { offenders.append("\(file):\(index + 1): \(code)") }
            }
        }
        XCTAssertEqual(offenders, [], "Build these from AtelierAction with actions.button/toggle/menuItem")
    }
}
