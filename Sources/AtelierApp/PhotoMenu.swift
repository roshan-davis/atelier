import AppKit
import AtelierCore

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

extension LibraryModel {
    /// The right-click menu for photos, shared by the grid, loupe and develop views. It acts on
    /// `targetIDs`, so callers select the clicked photo first.
    func photoMenu(includeZoom: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ids = targetIDs
        guard !ids.isEmpty else { return menu }
        let detail = ids.count == 1 ? self.detail : nil
        let count = ids.count > 1 ? " (\(ids.count) Photos)" : ""

        if mode != .loupe { menu.addItem(ClosureMenuItem("Open in Loupe") { self.openLoupe() }) }
        if mode != .develop { menu.addItem(ClosureMenuItem("Edit in Develop") { self.openDevelop() }) }
        menu.addItem(submenu("Edit In", editInMenu()))

        if includeZoom {
            menu.addItem(.separator())
            for level in ZoomLevel.presets {
                let title = level == .fit ? "Zoom to Fit" : level == .fill ? "Zoom to Fill" : "Zoom to \(level.label)"
                menu.addItem(ClosureMenuItem(title, checked: zoom == level) { self.zoom = level })
            }
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show in Finder") { self.showInFinder() })

        menu.addItem(.separator())
        let rating = NSMenu()
        for stars in 0...5 {
            let title = stars == 0 ? "None" : String(repeating: "★", count: stars)
            rating.addItem(ClosureMenuItem(title, checked: detail?.metadata.rating == stars) { self.setRating(stars) })
        }
        menu.addItem(submenu("Set Rating", rating))

        let flag = NSMenu()
        for (title, value) in [("Picked", Flag.picked), ("Rejected", Flag.rejected), ("Unflagged", Flag.none)] {
            flag.addItem(ClosureMenuItem(title, checked: detail?.metadata.flag == value) { self.setFlag(value) })
        }
        menu.addItem(submenu("Set Flag", flag))

        let label = NSMenu()
        for value in ColorLabel.allCases {
            label.addItem(ClosureMenuItem(value.rawValue, checked: detail?.metadata.colorLabel == value) {
                self.toggleLabel(value)
            })
        }
        menu.addItem(submenu("Set Color Label", label))

        menu.addItem(.separator())
        let develop = NSMenu()
        develop.addItem(ClosureMenuItem("Copy Settings", enabled: ids.count == 1) { self.copyDevelopSettings() })
        develop.addItem(ClosureMenuItem("Paste Settings\(count)", enabled: self.develop.clipboard != nil) {
            self.pasteDevelopSettings()
        })
        develop.addItem(.separator())
        develop.addItem(ClosureMenuItem("Reset All Settings\(count)") { self.resetDevelopSettings() })
        menu.addItem(submenu("Develop Settings", develop))

        let presets = NSMenu()
        var lastGroup: String?
        for preset in self.develop.presets {
            if preset.group != lastGroup {
                if lastGroup != nil { presets.addItem(.separator()) }
                let header = NSMenuItem(title: preset.group, action: nil, keyEquivalent: "")
                header.isEnabled = false
                presets.addItem(header)
                lastGroup = preset.group
            }
            presets.addItem(ClosureMenuItem(preset.name) { self.develop.applyPreset(preset, onto: ids) })
        }
        menu.addItem(submenu("Apply Develop Preset\(count)", presets))

        if !sidebar.collections.isEmpty {
            let collections = NSMenu()
            for collection in sidebar.collections {
                guard let id = collection.id else { continue }
                collections.addItem(ClosureMenuItem(collection.name) { self.addSelection(toCollection: id) })
            }
            menu.addItem(submenu("Add to Collection", collections))
        }
        if case .collection = sidebarSelection {
            menu.addItem(ClosureMenuItem("Remove from This Collection") { self.removeSelectionFromCurrentCollection() })
        }
        if case .importGroup = sidebarSelection {
            menu.addItem(ClosureMenuItem("Remove from This Import") { self.removeSelectionFromCurrentImport() })
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Write XMP Metadata") { self.writeXMP(selectionOnly: true) })
        menu.addItem(ClosureMenuItem("Export\(count)…") { self.beginExport() })
        return menu
    }

    /// The installed editors, then Other Application… and the Edit In settings.
    func editInMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for editor in externalEditors {
            let item = ClosureMenuItem("Edit in \(editor.name)") { self.editIn(editor) }
            let icon = editor.icon
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !externalEditors.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("Other Application…") { self.editInOtherApp() })
        return menu
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
