import Foundation

/// Binds an app's actions to their handlers. Menus, keys and (from AT-050b) agents run actions
/// only through it. A handler gets its targets already resolved: from the selection when the
/// person runs it, or named explicitly by the caller (the right-click menu, an agent).
@MainActor
public final class ActionRegistry<Context: AnyObject, TargetID: Hashable> {
    public typealias Resolver = @MainActor (Context, TargetKind) -> [TargetID]

    public let catalog: ActionCatalog
    private weak var context: Context?
    private let resolve: Resolver
    private var bindings: [ActionID: Handler] = [:]
    /// Binding mistakes (an action missing from the catalog, bound twice). Tests require none;
    /// the app keeps running either way.
    public private(set) var problems: [String] = []

    private struct Handler {
        let targets: TargetKind?
        let perform: @MainActor (Context, Any, [TargetID]) -> Bool
        let decode: (Data) throws -> Any
        let enabled: @MainActor (Context) -> Bool
        let isOn: (@MainActor (Context) -> Bool)?
        let shortcutWhen: (@MainActor (Context) -> Bool)?
    }

    public init(catalog: ActionCatalog, context: Context, resolveTargets: @escaping Resolver) {
        self.catalog = catalog
        self.context = context
        self.resolve = resolveTargets
    }

    // MARK: Binding

    /// Binds a handler that always applies.
    public func bind<P>(_ action: Action<P>,
                        enabled: @escaping @MainActor (Context) -> Bool = { _ in true },
                        isOn: (@MainActor (Context) -> Bool)? = nil,
                        shortcutWhen: (@MainActor (Context) -> Bool)? = nil,
                        run: @escaping @MainActor (Context, P, [TargetID]) -> Void) {
        bindChecked(action, enabled: enabled, isOn: isOn, shortcutWhen: shortcutWhen) { context, parameters, targets in
            run(context, parameters, targets)
            return true
        }
    }

    /// Binds a handler that reports whether it applied (a key that does nothing in this view
    /// returns false, so the key press goes on to the next responder).
    public func bindChecked<P>(_ action: Action<P>,
                               enabled: @escaping @MainActor (Context) -> Bool = { _ in true },
                               isOn: (@MainActor (Context) -> Bool)? = nil,
                               shortcutWhen: (@MainActor (Context) -> Bool)? = nil,
                               run: @escaping @MainActor (Context, P, [TargetID]) -> Bool) {
        let id = action.id
        if catalog.descriptor(id) != action.descriptor {
            problems.append("\(id): bound but not in the \(catalog.app) catalog")
        }
        if bindings[id] != nil { problems.append("\(id): bound twice") }
        bindings[id] = Handler(
            targets: action.descriptor.targets,
            perform: { context, parameters, targets in
                guard let parameters = parameters as? P else { return false }
                return run(context, parameters, targets)
            },
            decode: { data in try JSONDecoder().decode(P.self, from: data) },
            enabled: enabled, isOn: isOn, shortcutWhen: shortcutWhen)
    }

    /// Catalog actions with no handler. Tests require none.
    public var unbound: [ActionID] {
        catalog.actions.map(\.id).filter { bindings[$0] == nil }
    }

    // MARK: Running

    /// Runs an action. Without `targets`, they come from the current selection.
    @discardableResult
    public func run<P>(_ action: Action<P>, _ parameters: P, targets: [TargetID]? = nil) -> Bool {
        perform(action.id, parameters, targets: targets)
    }

    @discardableResult
    public func run(_ action: Action<NoParameters>, targets: [TargetID]? = nil) -> Bool {
        perform(action.id, NoParameters(), targets: targets)
    }

    /// Runs an action from JSON parameters, as an agent sends them. Throws when they don't
    /// decode; returns false when the action isn't bound or doesn't apply.
    @discardableResult
    public func run(_ id: ActionID, json parameters: Data, targets: [TargetID]? = nil) throws -> Bool {
        guard let binding = bindings[id] else { return false }
        let decoded = try binding.decode(parameters.isEmpty ? Data("{}".utf8) : parameters)
        return perform(id, decoded, targets: targets)
    }

    private func perform(_ id: ActionID, _ parameters: Any, targets: [TargetID]?) -> Bool {
        guard let context, let binding = bindings[id] else { return false }
        let resolved = targets ?? binding.targets.map { resolve(context, $0) } ?? []
        return binding.perform(context, parameters, resolved)
    }

    // MARK: State for menus

    public func descriptor<P>(_ action: Action<P>) -> ActionDescriptor { action.descriptor }

    public func isEnabled(_ id: ActionID) -> Bool {
        guard let context, let binding = bindings[id] else { return false }
        return binding.enabled(context)
    }

    public func isOn(_ id: ActionID) -> Bool {
        guard let context, let isOn = bindings[id]?.isOn else { return false }
        return isOn(context)
    }

    /// The shortcut to show now, if any: an action can hold its key only in some modes.
    public func activeShortcut(_ id: ActionID) -> KeyShortcut? {
        guard let descriptor = catalog.descriptor(id), let shortcut = descriptor.shortcut else { return nil }
        guard let context, let when = bindings[id]?.shortcutWhen else { return shortcut }
        return when(context) ? shortcut : nil
    }
}
