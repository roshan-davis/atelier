import AgentActions
import AgentMCP
import AtelierActions
import AtelierCore
import Foundation

/// An atomic batch while it runs: the photos it touched, each photo's state before its first
/// step, and whether the person already allowed it.
final class AgentBatchRun {
    let atomic: Bool
    let label: String
    var confirmed = false
    private(set) var photos: Set<Int64> = []
    private(set) var named: [Int64] = []
    private(set) var before: [Int64: PhotoState] = [:]

    init(atomic: Bool, label: String) {
        self.atomic = atomic
        self.label = label
    }

    /// The state before the batch: a photo's first state of each kind is kept.
    func remember(_ states: [Int64: PhotoState], named ids: [Int64]) {
        for (id, state) in states {
            before[id] = (before[id] ?? PhotoState()).filling(from: state)
            photos.insert(id)
        }
        for id in ids where !named.contains(id) { named.append(id) }
    }
}

/// `command_batch` (AT-050j): several changes in one call. Without `atomic`, each step is its
/// own change, as if called alone. With it, the batch is one change with one Undo: library
/// steps run as they come and are put back if a later step fails; Develop steps are held
/// (`DevelopController.beginStaging`) and land as one history step per photo at the end.
extension AgentServer {
    func callBatch(_ arguments: [String: JSONValue], client: AgentClient, profile: AgentProfile) -> MCPToolResult {
        guard profile >= .organize else {
            return .error("command_batch needs the Organize profile. The person can change that in Atelier > Settings… > Agents.")
        }
        guard let model else { return .error("\(Self.appName) is closing.") }
        let batch: CommandBatchTool.Batch
        switch CommandBatchTool.parse(arguments, tools: AtelierAgentTools.batchTools(profile: profile)) {
        case .failure(let problems): return .error(problems.text + " Nothing was changed.")
        case .success(let value): batch = value
        }
        if batch.atomic {
            let refusals = batch.steps.enumerated().compactMap { index, step in
                AtelierAgentTools.atomicRefusal(step).map { "Step \(index + 1) (\(step.tool)): \($0)" }
            }
            guard refusals.isEmpty else { return .error(refusals.joined(separator: " ") + " Nothing was changed.") }
            return runAtomic(batch, client, profile, model)
        }
        return runInTurn(batch, keepGoing: arguments["keep_going"]?.boolValue ?? false, client, profile)
    }

    // MARK: One change each

    private func runInTurn(_ batch: CommandBatchTool.Batch, keepGoing: Bool, _ client: AgentClient,
                           _ profile: AgentProfile) -> MCPToolResult {
        var steps: [JSONValue] = []
        var failed = 0
        var stoppedAt: Int?
        for (index, step) in batch.steps.enumerated() {
            let result = callWrite(step.tool, step.arguments, client: client, profile: profile)
                ?? .error("\(step.tool) can't be in a batch.")
            steps.append(Self.report(index, step, result))
            if result.isError {
                failed += 1
                if !keepGoing { stoppedAt = index + 1; break }
            }
        }
        var reply: [String: JSONValue] = [
            "catalog": .string(catalogName),
            "batch": .string(batch.label),
            "atomic": .bool(false),
            "steps": .array(steps),
            "done": .int(steps.count - failed),
            "failed": .int(failed),
        ]
        if let stoppedAt, stoppedAt < batch.steps.count {
            reply["not_run"] = .int(batch.steps.count - stoppedAt)
            reply["note"] = .string("Step \(stoppedAt) failed, so the \(batch.steps.count - stoppedAt) after it didn't run. "
                                    + "The steps before it stand; each has its own change id for undo_change.")
        }
        return .json(.object(reply))
    }

    // MARK: All or nothing

    private func runAtomic(_ batch: CommandBatchTool.Batch, _ client: AgentClient, _ profile: AgentProfile,
                           _ model: LibraryModel) -> MCPToolResult {
        let run = AgentBatchRun(atomic: true, label: batch.label)
        batchRun = run
        model.develop.beginStaging()
        defer {
            batchRun = nil
            model.develop.discardStaged()
        }
        var steps: [JSONValue] = []
        for (index, step) in batch.steps.enumerated() {
            let result = callWrite(step.tool, step.arguments, client: client, profile: profile)
                ?? .error("\(step.tool) can't be in a batch.")
            if result.isError {
                let putBack = rollBack(run, model)
                return .error("Step \(index + 1) (\(step.tool)) failed: \(result.text) "
                              + (putBack ? "Nothing was changed: the batch's earlier steps were put back."
                                         : "Atelier couldn't put back the earlier steps: \(model.status ?? "the catalog refused").")
                              + Self.newCollectionNote(steps))
            }
            steps.append(Self.report(index, step, result))
        }
        do {
            try model.develop.commitStaged(step: "\(batch.label) (\(client.name))")
        } catch {
            let putBack = rollBack(run, model)
            return .error("Atelier couldn't save the Develop changes: \(error.localizedDescription) "
                          + (putBack ? "The batch's other steps were put back." : "Some library steps couldn't be put back."))
        }
        guard !run.before.isEmpty else {
            return .json(.object(["catalog": .string(catalogName), "batch": .string(batch.label), "atomic": .bool(true),
                                  "steps": .array(steps), "note": .string("No photo changed.")]))
        }
        let after: [Int64: PhotoState]
        do {
            after = try states(shapedLike: run.before, model)
        } catch {
            return .error("The batch was made, but Atelier couldn't read the photos back for undo: \(error.localizedDescription)")
        }
        let change = changes.record(clientID: client.id, clientName: client.name, title: batch.label, targets: run.named,
                                    before: run.before, after: after, cantUndo: nil)
        let unchanged = run.before.keys.filter { run.before[$0] == after[$0] }.count
        announce("\(client.name): \(batch.label) (\(Self.count(run.named.count)))", change: change.id)
        log(client.name, .call, "\(change.id): \(batch.label), \(batch.steps.count) steps, \(Self.count(run.named.count))")
        var reply: [String: JSONValue] = [
            "change": .string(change.id),
            "catalog": .string(catalogName),
            "batch": .string(batch.label),
            "atomic": .bool(true),
            "steps": .array(steps),
            "photos": .int(run.named.count),
            "ids": .array(run.named.prefix(200).map { .int(Int($0)) }),
            "undo": .string("undo_change with change \"\(change.id)\" undoes the whole batch while it is still the latest "
                            + "change on those photos."),
        ]
        if unchanged > 0 { reply["already_so"] = .int(unchanged) }
        return .json(.object(reply))
    }

    /// Puts back the library fields the batch's steps changed. Develop steps were only held,
    /// so dropping them (`discardStaged`) leaves nothing to put back.
    private func rollBack(_ run: AgentBatchRun, _ model: LibraryModel) -> Bool {
        model.develop.discardStaged()
        let library = run.before.compactMapValues(\.library)
        guard !library.isEmpty else { return true }
        return model.performEdit(on: Array(library.keys)) { try $0.restoreLibraryStates(library) }
    }

    private static func report(_ index: Int, _ step: CommandBatchTool.Step, _ result: MCPToolResult) -> JSONValue {
        var entry: [String: JSONValue] = ["step": .int(index + 1), "tool": .string(step.tool), "ok": .bool(!result.isError)]
        if let command = step.arguments["id"], step.tool == CommandRunTool.name { entry["command"] = command }
        if result.isError {
            entry["error"] = .string(result.text)
        } else if let structured = result.structured {
            entry["result"] = structured
        }
        return .object(entry)
    }

    /// A collection a rolled-back step made stays, empty, as with undo.
    private static func newCollectionNote(_ steps: [JSONValue]) -> String {
        let made = steps.contains { $0["result"]?["collection_id"] != nil }
        return made ? " A new collection it made stays, empty." : ""
    }
}
