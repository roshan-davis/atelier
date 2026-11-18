import AppKit
import StudioMarkdownEditor
import StudioSkills
import StudioSkillsUI
import SwiftUI

/// The Edit Skill windows (SL-002c, Skills PRD "The Edit Skill window"): one per skill, opened
/// from Settings > Agents > Skills. Each is its own resizable window, at least 640 × 440,
/// centered over the window it was opened from the first time and then where it was left.
/// Closing it with unsaved changes asks Save, Don't Save or Cancel, as a document window does.
@MainActor
final class EditSkillWindows {
    static let shared = EditSkillWindows()

    /// The open windows.
    private var windows: [ObjectIdentifier: EditSkillWindow] = [:]

    /// Opens Edit Skill on `skill`, or on a new skill when it is nil. A skill already open in a
    /// window brings that window to the front.
    func open(_ skill: Skill?, skills: AgentSkills) {
        if let skill, let window = windows.values.first(where: { $0.model.original?.name == skill.name }) {
            window.window.makeKeyAndOrderFront(nil)
            return
        }
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let editor = EditSkillWindow(skill: skill, skills: skills) { [weak self] closed in
            self?.windows[ObjectIdentifier(closed)] = nil
        }
        windows[ObjectIdentifier(editor)] = editor
        editor.show(over: parent)
    }
}

/// One Edit Skill window.
@MainActor
final class EditSkillWindow: NSObject, NSWindowDelegate {
    static let autosaveName = "AtelierEditSkill"
    static let defaultSize = CGSize(width: 820, height: 600)

    let model: EditSkillModel
    let window: NSWindow
    private let store: SkillStore
    private let closed: (EditSkillWindow) -> Void

    init(skill: Skill?, skills: AgentSkills, closed: @escaping (EditSkillWindow) -> Void) {
        store = skills.store
        model = EditSkillModel(skill: skill, catalog: skills.catalog, takenNames: Set(skills.store.skills.map(\.name)))
        self.closed = closed
        window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.defaultSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = skill.map { "Edit Skill: \($0.displayTitle)" } ?? "New Skill"
        window.isReleasedWhenClosed = false
        window.minSize = EditSkillView.minimumSize
        window.delegate = self
        let view = EditSkillView(model: model, onCancel: { [weak self] in self?.close(saving: false) },
                                 onSave: { [weak self] skill, previousName in try self?.save(skill, previousName: previousName) })
            .markdownEditorStyle(.atelier(Theme.current))
            .environment(\.theme, Theme.current)
        window.contentView = NSHostingView(rootView: view)
    }

    /// Centered over `parent` the first time; after that where the person left the last one.
    func show(over parent: NSWindow?) {
        if let parent {
            let frame = parent.frame
            window.setFrameOrigin(CGPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        window.makeKeyAndOrderFront(nil)
    }

    private func save(_ skill: Skill, previousName: String?) throws {
        try store.save(skill, previousName: previousName)
        close(saving: false)
    }

    /// Saves the draft (when asked), then closes. A save that fails keeps the window open with
    /// the error in its status line.
    private func close(saving: Bool) {
        if saving {
            guard let skill = model.skillToSave() else { return }
            do {
                try store.save(skill, previousName: model.original?.name)
            } catch {
                model.saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }
        window.delegate = nil
        window.close()
        closed(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasChanges, !(model.original == nil && model.draft == Skill(name: model.draft.name)) else {
            close(saving: false)
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(model.draft.displayTitle)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.close(saving: true)
            case .alertThirdButtonReturn: self?.close(saving: false)
            default: break
            }
        }
        return false
    }
}
