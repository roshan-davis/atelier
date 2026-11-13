import AgentActions
import AgentMCP
import AtelierActions
import AtelierCore
import Foundation

/// The Edit profile's Develop tools (AT-050d): adjust, apply_preset, sync and reset. Each call
/// is one change through the same guard as the Organize tools (resolve once, ask above the
/// limit, record before and after), saved as one step in each photo's Develop history named for
/// the app, so the person sees it there and undo_change or the notice's Undo puts it back.
extension AgentServer {
    func callDevelop(_ tool: String, _ arguments: [String: JSONValue], client: AgentClient,
                     profile: AgentProfile) -> MCPToolResult {
        guard profile >= .edit else {
            return .error("\(tool) needs the Edit profile. The person can change that in Atelier > Settings… > Agents.")
        }
        guard let model else { return .error("\(Self.appName) is closing.") }
        do {
            switch tool {
            case AtelierAgentTools.adjust.name:
                return try adjust(try decode(AdjustParameters.self, arguments), client, model)
            case AtelierAgentTools.applyPreset.name:
                return try applyPreset(try decode(ApplyPresetParameters.self, arguments), client, model)
            case AtelierAgentTools.sync.name:
                return try sync(try decode(SyncParameters.self, arguments), client, model)
            case AtelierAgentTools.reset.name:
                return try reset(try decode(ResetParameters.self, arguments), client, model)
            default:
                return .error("Unknown tool: \(tool).")
            }
        } catch let problem as ArgumentProblem {
            return .error(problem.message)
        } catch {
            return .error("Atelier couldn't make the change: \(error.localizedDescription)")
        }
    }

    /// Every Develop slider by its agent name ("hue_red").
    static let developSliders: [String: (DevelopSettings.Parameter, DevelopSlider)] = {
        var sliders: [String: (DevelopSettings.Parameter, DevelopSlider)] = [:]
        for parameter in DevelopSettings.Parameter.allCases {
            let name = AdjustRules.snakeName(parameter.rawValue)
            sliders[name] = (parameter, DevelopSlider(name: name, range: parameter.range))
        }
        return sliders
    }()

    // MARK: adjust

    private func adjust(_ parameters: AdjustParameters, _ client: AgentClient, _ model: LibraryModel) throws -> MCPToolResult {
        let changes: [(DevelopSlider, Double)]
        switch AdjustRules.changes(parameters, sliders: Self.developSliders.mapValues { $0.1 }) {
        case .failure(let problems): throw ArgumentProblem(problems.text)
        case .success(let value): changes = value
        }
        let mode = parameters.mode ?? .set
        let title = AdjustRules.title(changes, mode: mode)
        var clamped: Set<String> = []
        var asShot: [Int64] = []
        let result = try write(parameters, title: title, client, model, kind: .develop) { named, _ in
            let current = try model.develop.currentSettings(for: named)
            var updated: [Int64: DevelopSettings] = [:]
            for id in named {
                guard var settings = current[id] else { continue }
                for (slider, asked) in changes {
                    guard let parameter = Self.developSliders[slider.name]?.0 else { continue }
                    if parameter == .temperature, mode == .add, settings.temperature == nil {
                        // As Shot has no number here to add to.
                        asShot.append(id)
                        continue
                    }
                    let (value, wasClamped) = AdjustRules.value(current: settings[parameter], asked: asked, mode: mode,
                                                               range: parameter.range)
                    if wasClamped { clamped.insert(slider.name) }
                    settings[parameter] = value
                    // As in Lightroom, changing a slider in a panel that is off turns the panel on.
                    if !settings.isOn(parameter.panel) { settings.setPanel(parameter.panel, on: true) }
                }
                updated[id] = settings
            }
            try model.develop.apply(each: updated, step: "\(title) (\(client.name))")
        }
        var notes: [String] = []
        if !clamped.isEmpty {
            notes.append("Kept at the end of their range: \(clamped.sorted().joined(separator: ", ")).")
        }
        if !asShot.isEmpty {
            notes.append("Temperature wasn't changed on \(Self.count(asShot.count)) whose White Balance is As Shot "
                         + "(ids \(asShot.prefix(20).map(String.init).joined(separator: ", "))); set it with mode set instead.")
        }
        return adding(notes, to: result)
    }

    // MARK: apply_preset

    private func applyPreset(_ parameters: ApplyPresetParameters, _ client: AgentClient,
                             _ model: LibraryModel) throws -> MCPToolResult {
        let preset = try findPreset(parameters.preset, model)
        let title = "Preset: \(preset.name)"
        let result = try write(parameters, title: title, client, model, kind: .develop) { named, _ in
            let current = try model.develop.currentSettings(for: named)
            try model.develop.apply(each: current.mapValues { preset.applied(to: $0) }, step: "\(title) (\(client.name))")
        }
        return adding(["preset": .string(preset.id.uuidString)], to: result)
    }

    private func findPreset(_ text: String, _ model: LibraryModel) throws -> DevelopPreset {
        let presets = model.develop.visiblePresets
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: wanted), let preset = presets.first(where: { $0.id == id }) { return preset }
        let named = presets.filter { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            let groups = named.map { "\($0.group): \($0.id.uuidString)" }.joined(separator: "; ")
            throw ArgumentProblem("\(named.count) presets are called “\(wanted)” (\(groups)). Name one by its id.")
        }
        let hint = Suggest.closest(to: wanted, in: presets.map(\.name)).map { " Did you mean “\($0)”?" } ?? ""
        throw ArgumentProblem("No Develop preset “\(wanted)”.\(hint) list_items with kind presets lists them.")
    }

    // MARK: sync

    private func sync(_ parameters: SyncParameters, _ client: AgentClient, _ model: LibraryModel) throws -> MCPToolResult {
        let source = try resolve(SourcePhoto(ids: [parameters.from], catalog: parameters.catalog), model)[0]
        let parts = parameters.parts ?? DevelopPart.syncDefault
        guard !parts.isEmpty else { throw ArgumentProblem("parts is empty: name at least one part, or leave it out.") }
        let from = try model.develop.currentSettings(for: [source])[source] ?? .neutral
        let preset = DevelopPreset(name: "Sync", parts: Set(parts.map(\.presetPart)), settings: from)
        let title = parameters.parts == nil ? "Sync Settings from photo \(source)"
            : "Sync \(parts.map(\.presetPart.title).joined(separator: ", ")) from photo \(source)"
        return try write(parameters, title: title, client, model, kind: .develop) { named, _ in
            let targets = named.filter { $0 != source }
            guard !targets.isEmpty else { throw ArgumentProblem("Name the photos to copy onto; only photo \(source) was named.") }
            let current = try model.develop.currentSettings(for: targets)
            try model.develop.apply(each: current.mapValues { preset.applied(to: $0) }, step: "\(title) (\(client.name))")
        }
    }

    // MARK: reset

    private func reset(_ parameters: ResetParameters, _ client: AgentClient, _ model: LibraryModel) throws -> MCPToolResult {
        let title = parameters.parts.map { "Reset \($0.map(\.presetPart.title).joined(separator: ", "))" } ?? "Reset All"
        if let parts = parameters.parts, parts.isEmpty {
            throw ArgumentProblem("parts is empty: name at least one part, or leave it out to reset everything.")
        }
        return try write(parameters, title: title, client, model, kind: .develop) { named, _ in
            let current = try model.develop.currentSettings(for: named)
            let updated: [Int64: DevelopSettings]
            if let parts = parameters.parts {
                let neutral = DevelopPreset(name: "Reset", parts: Set(parts.map(\.presetPart)), settings: .neutral)
                updated = current.mapValues { neutral.applied(to: $0) }
            } else {
                updated = current.mapValues { _ in .neutral }
            }
            try model.develop.apply(each: updated, step: "\(title) (\(client.name))")
        }
    }

    // MARK: Helpers

    private struct SourcePhoto: PhotoTargeting {
        var ids: [Int64]?
        var selection: Bool? { nil }
        var current: Bool? { nil }
        var catalog: String?
    }

    private func adding(_ notes: [String], to result: MCPToolResult) -> MCPToolResult {
        guard !notes.isEmpty else { return result }
        return adding(["note": .string(notes.joined(separator: " "))], to: result)
    }

    private func adding(_ members: [String: JSONValue], to result: MCPToolResult) -> MCPToolResult {
        guard case .object(var reply)? = result.structured, !result.isError else { return result }
        for (key, value) in members { reply[key] = value }
        return .json(.object(reply))
    }

    /// Before a Develop tool runs: a slider or handle the person is dragging finishes first
    /// (up to 10 seconds), so the agent's step never lands inside theirs.
    func waitForDevelopIdle() async -> Bool {
        for _ in 0..<100 {
            guard model?.develop.isEditingByHand == true else { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return model?.develop.isEditingByHand != true
    }
}

extension DevelopPart {
    var presetPart: DevelopPreset.Part {
        switch self {
        case .profile: return .profile
        case .treatment: return .treatment
        case .whiteBalance: return .whiteBalance
        case .exposure: return .exposure
        case .tone: return .tone
        case .presence: return .presence
        case .toneCurve: return .toneCurve
        case .hsl: return .hsl
        case .colorGrading: return .colorGrading
        case .detail: return .detail
        case .lensCorrections: return .lensCorrections
        case .transform: return .transform
        case .effects: return .effects
        case .crop: return .crop
        case .masks: return .masks
        }
    }
}
