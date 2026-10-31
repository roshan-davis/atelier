import Foundation

/// How far ComfyUI has got with one prompt, worked out from the messages on its websocket.
///
/// Each node the prompt runs counts by how long it usually takes: what it took on earlier runs
/// of the same recipe and size, or a guess by its kind until then. The node that is running
/// counts by its own step progress when it reports one (samplers, tiled upscales), otherwise
/// by its time so far against its usual time. Nodes ComfyUI skips because their result is
/// cached (the models, once loaded) drop out of the total.
public struct ComfyProgress: Sendable {
    /// Node id to class type, for every node in the workflow.
    private let classes: [String: String]
    /// Node id to its expected seconds.
    private let expected: [String: TimeInterval]
    private var skipped: Set<String> = []
    private var done: Set<String> = []
    private var current: String?
    private var currentStart: Date?
    private var currentStep: Double?
    private var started = false
    private var finished = false
    private var shown = 0.0
    private var totals: [String: (seconds: TimeInterval, count: Int)] = [:]

    /// How long a node of each class took on this run, on average, to learn from for the next one.
    public var measured: [String: TimeInterval] {
        totals.mapValues { $0.seconds / Double($0.count) }
    }

    public init(workflow: [String: Any], known: [String: TimeInterval] = [:]) {
        var classes: [String: String] = [:]
        var expected: [String: TimeInterval] = [:]
        for (id, value) in workflow {
            guard let node = value as? [String: Any], let type = node["class_type"] as? String else { continue }
            classes[id] = type
            expected[id] = known[type] ?? Self.guess(for: type)
        }
        self.classes = classes
        self.expected = expected
    }

    /// Seconds a node of this kind takes before Lightfast has timed one, on an Apple Silicon Mac.
    /// Only the proportions matter, and only until the first run has been measured.
    static func guess(for classType: String) -> TimeInterval {
        let name = classType.lowercased()
        if name.contains("loader") { return 10 }
        if (name.contains("ksampler") && !name.contains("select")) || name.hasPrefix("samplercustom") { return 60 }
        if name.contains("upscalewithmodel") { return 30 }
        if name.contains("textencode") { return 10 }
        if name.hasPrefix("vaedecode") || name.hasPrefix("vaeencode") { return 8 }
        return 0.5
    }

    /// Applies one websocket message (already decoded from JSON).
    public mutating func apply(_ message: [String: Any], at now: Date = Date()) {
        guard let type = message["type"] as? String else { return }
        let data = message["data"] as? [String: Any] ?? [:]
        switch type {
        case "execution_start":
            started = true
        case "execution_cached":
            started = true
            for case let id as String in data["nodes"] as? [Any] ?? [] where classes[id] != nil { skipped.insert(id) }
        case "executing":
            started = true
            finishCurrent(at: now)
            // Nodes a node expands into report their own ids; display_node is the one in the workflow.
            let node = [data["display_node"], data["node"]].compactMap { $0 as? String }.first { classes[$0] != nil }
                ?? data["node"] as? String
            if let node {
                current = node
                currentStart = now
                currentStep = nil
            } else if data.keys.contains("node") {
                // "node": null means the prompt is done.
                finished = true
            }
        case "progress":
            started = true
            step(data["value"], of: data["max"], node: data["node"] as? String, at: now)
        case "progress_state":
            started = true
            for (id, entry) in data["nodes"] as? [String: Any] ?? [:] {
                guard let value = entry as? [String: Any] else { continue }
                let key = (value["display_node_id"] as? String).flatMap { classes[$0] != nil ? $0 : nil } ?? id
                switch value["state"] as? String {
                case "finished" where classes[key] != nil && key != current: done.insert(key)
                // Every running node shows 0 of 1 here; only more than one step is real progress.
                case "running" where ((value["max"] as? NSNumber)?.doubleValue ?? 0) > 1:
                    step(value["value"], of: value["max"], node: key, at: now)
                default: break
                }
            }
        case "executed":
            if let node = data["node"] as? String, node == current { finishCurrent(at: now) }
        case "execution_success", "execution_error", "execution_interrupted":
            finishCurrent(at: now)
            finished = true
        default:
            break
        }
    }

    /// 0...1, or nil until ComfyUI has started on the prompt (it may be queued behind another).
    /// Never goes back, and stays under 100% until ComfyUI says it is done.
    public mutating func fraction(at now: Date = Date()) -> Double? {
        guard started else { return nil }
        if finished { return 1 }
        let counted = expected.filter { !skipped.contains($0.key) }
        let total = counted.values.reduce(0, +)
        guard total > 0 else { return nil }
        var progress = counted.filter { done.contains($0.key) }.values.reduce(0, +)
        if let current, !done.contains(current), let seconds = counted[current] {
            let elapsed = currentStart.map { now.timeIntervalSince($0) } ?? 0
            progress += seconds * (currentStep ?? min(elapsed / max(seconds, 0.1), 0.9))
        }
        shown = max(shown, min(progress / total, 0.99))
        return shown
    }

    private mutating func step(_ value: Any?, of maximum: Any?, node: String?, at now: Date) {
        guard let value = (value as? NSNumber)?.doubleValue, let maximum = (maximum as? NSNumber)?.doubleValue,
              maximum > 0 else { return }
        if let node, classes[node] != nil, node != current, !done.contains(node) {
            finishCurrent(at: now)
            current = node
            currentStart = now
        }
        currentStep = min(max(value / maximum, 0), 1)
    }

    private mutating func finishCurrent(at now: Date) {
        guard let current else { return }
        if let type = classes[current], !done.contains(current), let start = currentStart {
            let total = totals[type] ?? (0, 0)
            totals[type] = (total.seconds + now.timeIntervalSince(start), total.count + 1)
        }
        if classes[current] != nil { done.insert(current) }
        self.current = nil
        currentStart = nil
        currentStep = nil
    }
}

/// What each node class took on earlier runs, per recipe and size, so the next run's
/// percentage matches this Mac.
public enum ComfyTimings {
    static func defaultsKey(_ key: String) -> String { "ai.nodeSeconds.\(key)" }

    public static func load(_ key: String) -> [String: TimeInterval] {
        UserDefaults.standard.dictionary(forKey: defaultsKey(key)) as? [String: TimeInterval] ?? [:]
    }

    /// Blends this run's times into the stored ones, half and half, so one slow run (the first,
    /// loading models from disk) doesn't skew the next too far.
    public static func save(_ measured: [String: TimeInterval], key: String) {
        guard !measured.isEmpty else { return }
        var stored = load(key)
        for (type, seconds) in measured {
            stored[type] = stored[type].map { ($0 + seconds) / 2 } ?? seconds
        }
        UserDefaults.standard.set(stored, forKey: defaultsKey(key))
    }
}
