// Menu builders: the only way an app makes a menu item, key or right-click item for an action.
// Mac only; the rest of the module builds anywhere (its tests also run on Linux).
#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI

/// A right-click (AppKit) menu item that runs one action.
public final class ActionMenuItem: NSMenuItem {
    public let actionID: ActionID
    private let handler: () -> Void

    public init(_ title: String, action id: ActionID, checked: Bool = false, enabled: Bool = true,
                handler: @escaping () -> Void) {
        actionID = id
        self.handler = handler
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    public required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func runAction() { handler() }
}

public extension ActionRegistry {
    /// A right-click item. Its targets are the ones the menu was built for.
    func menuItem<P>(_ action: Action<P>, _ parameters: P, title: String? = nil, checked: Bool = false,
                     enabled: Bool = true, targets: [TargetID]? = nil) -> NSMenuItem {
        ActionMenuItem(title ?? action.descriptor.title, action: action.id, checked: checked, enabled: enabled) { [weak self] in
            self?.run(action, parameters, targets: targets)
        }
    }

    func menuItem(_ action: Action<NoParameters>, title: String? = nil, checked: Bool = false,
                  enabled: Bool = true, targets: [TargetID]? = nil) -> NSMenuItem {
        menuItem(action, NoParameters(), title: title, checked: checked, enabled: enabled, targets: targets)
    }

    /// A menu bar item: the action's title, its shortcut (when it holds it now) and whether it
    /// applies now.
    func button<P>(_ action: Action<P>, _ parameters: P, title: String? = nil,
                   showsShortcut: Bool = true) -> some View {
        let shortcut = showsShortcut ? activeShortcut(action.id)?.keyboardShortcut : nil
        return Button(title ?? action.descriptor.title) { self.run(action, parameters) }
            .keyboardShortcut(shortcut)
            .disabled(!isEnabled(action.id))
    }

    func button(_ action: Action<NoParameters>, title: String? = nil, showsShortcut: Bool = true) -> some View {
        button(action, NoParameters(), title: title, showsShortcut: showsShortcut)
    }

    /// A menu bar item with a checkmark.
    func toggle(_ action: Action<NoParameters>, title: String? = nil) -> some View {
        Toggle(title ?? action.descriptor.title, isOn: Binding(get: { self.isOn(action.id) },
                                                              set: { _ in self.run(action) }))
            .keyboardShortcut(activeShortcut(action.id)?.keyboardShortcut)
            .disabled(!isEnabled(action.id))
    }
}

public extension KeyShortcut {
    var keyboardShortcut: KeyboardShortcut? {
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if key.count == 1, let character = key.first {
            return KeyboardShortcut(KeyEquivalent(character), modifiers: flags)
        }
        if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...12).contains(number),
           let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
            return KeyboardShortcut(KeyEquivalent(Character(scalar)), modifiers: flags)
        }
        return nil
    }
}
#endif
