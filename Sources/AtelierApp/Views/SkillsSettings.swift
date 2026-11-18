import AppKit
import StudioMarkdownEditor
import StudioSkills
import StudioSkillsUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Agents > Skills (SL-002c): the library's list of the person's skills, with
/// Atelier's delete sound, Open and Save panels and the Edit Skill window.
struct SkillsSettingsSection: View {
    let skills: AgentSkills
    @ObservedObject var store: SkillStore
    @State private var selection: String?
    @State private var problem: String?

    init(skills: AgentSkills) {
        self.skills = skills
        _store = ObservedObject(wrappedValue: skills.store)
    }

    var body: some View {
        SettingsSection("Skills") {
            SkillsList(skills: store.skills, checker: SkillChecker(catalog: skills.catalog), selection: $selection,
                       actions: actions)
                .frame(height: 230)
                .markdownEditorStyle(.atelierSettings)
            ForEach(store.unreadable.keys.sorted(), id: \.self) { name in
                Text("Couldn't read the skill folder “\(name)”: \(store.unreadable[name] ?? "")")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("A skill teaches chat apps a workflow in Atelier. Type / in a skill to add a command. Chat apps read skills that are on with get_skill, and Docent lists them under /. A skill doesn't change what an app may do: each app still has only its access above. Help > Atelier Help > Connect a chat app > Skills has more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: SkillsListActions {
        SkillsListActions(
            open: { name in EditSkillWindows.shared.open(store.skill(named: name), skills: skills) },
            new: { EditSkillWindows.shared.open(nil, skills: skills) },
            delete: { name in
                attempt {
                    try store.delete(name)
                    if selection == name { selection = nil }
                    DeleteFeedback.play(.trash)
                }
            },
            setEnabled: { name, enabled in attempt { try store.setEnabled(enabled, for: name) } },
            duplicate: { name in attempt { selection = try store.duplicate(name).name } },
            importSkill: importSkill,
            exportSkill: exportSkill,
            showInFinder: { name in NSWorkspace.shared.activateFileViewerSelecting([store.url(of: name)]) })
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A skill folder or a lone SKILL.md. It arrives switched off and opens in Edit Skill.
    private func importSkill() {
        let panel = NSOpenPanel()
        panel.title = "Import Skill"
        panel.message = "Choose a skill's folder, or its SKILL.md."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.folder, UTType(filenameExtension: "md") ?? UTType.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt {
            let skill = try store.importSkill(from: url)
            selection = skill.name
            EditSkillWindows.shared.open(skill, skills: skills)
        }
    }

    private func exportSkill(_ name: String) {
        let panel = NSOpenPanel()
        panel.title = "Export Skill"
        panel.message = "Choose where to put the skill's folder."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        attempt {
            let written = try store.export(name, to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([written])
        }
    }
}

extension MarkdownEditorStyle {
    /// The list in Settings: the grouped Form's row color, so it sits in its section.
    static var atelierSettings: MarkdownEditorStyle {
        MarkdownEditorStyle(background: Color(nsColor: .controlBackgroundColor))
    }

    /// The Edit Skill window: the theme's panel color around the editor.
    static func atelier(_ theme: Theme) -> MarkdownEditorStyle {
        MarkdownEditorStyle(background: Color(nsColor: theme.panel), popoverBackground: Color(nsColor: theme.panel))
    }
}
