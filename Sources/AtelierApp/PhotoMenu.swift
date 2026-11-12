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
        if mode != .hdr || ids.first != hdr.assetID {
            menu.addItem(ClosureMenuItem("Edit in HDR", enabled: ids.count == 1) { self.openHDR() })
        }
        menu.addItem(ClosureMenuItem("Create Virtual Copy\(ids.count > 1 ? "\(count)" : "")") { self.createVirtualCopies() })
        if targetsIncludeVirtualCopy {
            menu.addItem(ClosureMenuItem("Remove Virtual Copy…") { self.removeVirtualCopies() })
        }
        if ids.count == 1, let size = rows.first(where: { $0.id == ids[0] })?.cullGroupSize, size > 1 {
            menu.addItem(ClosureMenuItem("Show Cull Group (\(size) Shots)") { self.showCullGroup() })
        }
        menu.addItem(submenu("Edit In", editInMenu()))
        let ai = NSMenu()
        for recipe in AIRecipe.allCases {
            ai.addItem(ClosureMenuItem("\(recipe.title)…", enabled: ids.count == 1) { self.openAI(recipe) })
        }
        menu.addItem(submenu("AI", ai))

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

        // Recent, then one submenu per group, the user's groups first, as in the Presets panel.
        let presets = NSMenu()
        let recent = self.develop.recentPresets
        if !recent.isEmpty {
            let menu = NSMenu()
            for preset in recent {
                menu.addItem(ClosureMenuItem(preset.name) { self.develop.applyPreset(preset, onto: ids) })
            }
            presets.addItem(submenu("Recent", menu))
            presets.addItem(.separator())
        }
        var groupMenu: NSMenu?
        var lastGroup: (String, Bool)?
        for preset in self.develop.visiblePresets {
            if lastGroup?.0 != preset.group || lastGroup?.1 != preset.isBuiltIn {
                if lastGroup?.1 == false, preset.isBuiltIn { presets.addItem(.separator()) }
                let menu = NSMenu()
                presets.addItem(submenu(preset.group, menu))
                groupMenu = menu
                lastGroup = (preset.group, preset.isBuiltIn)
            }
            groupMenu?.addItem(ClosureMenuItem(preset.name) { self.develop.applyPreset(preset, onto: ids) })
        }
        menu.addItem(submenu("Apply Develop Preset\(count)", presets))
        menu.addItem(ClosureMenuItem("Match Look to Reference…", enabled: matchProgress == nil) {
            self.beginMatchLook(for: ids)
        })

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

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(ids.count > 1 ? "Remove \(ids.count) Photos…" : "Remove Photo…") {
            self.beginRemovePhotos()
        })
        return menu
    }

    /// The Filmstrip's right-click menu: the same photo menu, acting on the Filmstrip
    /// selection in every mode (as in Lightroom), with the right-clicked photo joining it.
    func filmstripMenu(for id: Int64) -> NSMenu {
        prepareContextMenu(for: id)
        menuTargets = rows.map(\.id).filter { selection.contains($0) }
        let menu = photoMenu(includeZoom: false)
        menu.delegate = FilmstripMenuCloser.shared
        FilmstripMenuCloser.shared.model = self
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

/// Clears the Filmstrip menu's targets once its item (if any) has run.
@MainActor
final class FilmstripMenuCloser: NSObject, NSMenuDelegate {
    static let shared = FilmstripMenuCloser()
    weak var model: LibraryModel?

    func menuDidClose(_ menu: NSMenu) {
        // The chosen item's action runs after the menu closes, in this same event.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model?.menuTargets = nil }
        }
    }
}
