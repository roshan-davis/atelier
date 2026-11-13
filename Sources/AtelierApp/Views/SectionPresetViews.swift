import AppKit
import AtelierCore
import SwiftUI

/// The Preset row at the top of the Tone Curve and Color Grading panels (Rosh, Nov 12, 2026):
/// a menu of presets that change only that panel, as Lightroom Classic's Point Curve menu and
/// Easel's Curves Preset menu do. It shows the preset the panel matches, or Custom. Resting on
/// a preset in the open menu previews it in the Navigator, as the Presets panel does; choosing
/// it is one history step. Save Preset… keeps the panel's current settings under a name.
struct SectionPresetRow: View {
    let kind: SectionPresetKind
    @ObservedObject var develop: DevelopController
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("Preset")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            SectionPresetPopUp(kind: kind, develop: develop, title: develop.sectionPresetTitle(kind)) {
                name = ""
                naming = true
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Save \(kind.title) Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { develop.saveSectionPreset(kind, named: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this photo's \(kind.title) settings, and nothing else, so you can apply them to any photo "
                 + "from this menu. A preset with the same name is replaced.")
        }
    }
}

/// An AppKit pull-down, because a SwiftUI menu can't tell which item the pointer rests on.
private struct SectionPresetPopUp: NSViewRepresentable {
    let kind: SectionPresetKind
    let develop: DevelopController
    let title: String
    let save: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        button.menu = menu
        button.toolTip = "\(kind.title) presets: rest on one to preview it in the Navigator, click to apply it. "
            + "Only \(kind.title) changes."
        button.setAccessibilityLabel("\(kind.title) Preset")
        context.coordinator.parent = self
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // A pull-down shows its first item's title.
        if let first = button.menu?.items.first, first.title != title {
            first.title = title
            button.synchronizeTitleAndSelectedItem()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: SectionPresetPopUp?

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let parent else { return }
            let kind = parent.kind, develop = parent.develop
            let match = develop.sectionPresetMatch(kind)
            menu.removeAllItems()
            menu.addItem(NSMenuItem(title: match?.name ?? "Custom", action: nil, keyEquivalent: ""))
            let user = develop.userSectionPresets[kind] ?? []
            var groups = kind.builtInGroups.map { group in (group, kind.builtIn.filter { $0.group == group }) }
            if !user.isEmpty { groups.append((DevelopPreset.defaultGroup, user)) }
            for (index, (group, presets)) in groups.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                menu.addItem(NSMenuItem.sectionHeader(title: group))
                for preset in presets {
                    let item = ClosureMenuItem(preset.name, checked: preset.id == match?.id) { [weak develop] in
                        develop?.applySectionPreset(preset, kind: kind)
                    }
                    item.representedObject = preset
                    item.isEnabled = develop.assetID != nil
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
            let save = parent.save
            menu.addItem(ClosureMenuItem("Save Preset…", enabled: develop.assetID != nil) { save() })
            if !user.isEmpty {
                let delete = NSMenu()
                for preset in user {
                    delete.addItem(ClosureMenuItem(preset.name) { [weak develop] in
                        develop?.deleteSectionPreset(preset, kind: kind)
                    })
                }
                let item = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
                item.submenu = delete
                menu.addItem(item)
            }
        }

        /// Resting on a preset previews it in the Navigator; anything else clears the preview.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            parent?.develop.previewPreset(item?.representedObject as? DevelopPreset)
        }

        func menuDidClose(_ menu: NSMenu) {
            parent?.develop.previewPreset(nil)
        }
    }
}
