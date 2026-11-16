import AgentActions
import AppKit
import AtelierActions
import AtelierCore

extension LibraryModel {
    /// The right-click menu for photos, shared by the grid, loupe and develop views. It acts on
    /// `targetIDs`, so callers select the clicked photo first. Every item is a registry action
    /// (see LibraryModel+Actions.swift) run on the photos the menu was built for.
    func photoMenu(includeZoom: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ids = targetIDs
        guard !ids.isEmpty else { return menu }
        let detail = ids.count == 1 ? self.detail : nil
        let count = ids.count > 1 ? " (\(ids.count) Photos)" : ""
        func item(_ action: Action<NoParameters>, _ title: String? = nil, enabled: Bool = true) -> NSMenuItem {
            actions.menuItem(action, title: title, enabled: enabled, targets: ids)
        }

        if mode != .loupe { menu.addItem(item(AtelierAction.loupe, "Open in Loupe")) }
        if mode != .develop { menu.addItem(item(AtelierAction.develop, "Edit in Develop")) }
        if mode != .hdr || ids.first != hdr.assetID {
            menu.addItem(item(AtelierAction.hdr, "Edit in HDR", enabled: ids.count == 1))
        }
        if !(mode == .develop && develop.isLensBlurring && ids.first == develop.assetID) {
            menu.addItem(item(AtelierAction.lensBlur, "Edit in Lens Blur", enabled: ids.count == 1))
        }
        menu.addItem(item(AtelierAction.createVirtualCopy, "Create Virtual Copy\(ids.count > 1 ? "\(count)" : "")"))
        if targetsIncludeVirtualCopy {
            menu.addItem(item(AtelierAction.removeVirtualCopy))
        }
        if ids.count == 1, let size = rows.first(where: { $0.id == ids[0] })?.cullGroupSize, size > 1 {
            menu.addItem(item(AtelierAction.showCullGroup, "Show Cull Group (\(size) Shots)"))
        }
        menu.addItem(item(AtelierAction.addNote, ids.count > 1 ? "Add Note\(count)…" : "Add Note…"))
        menu.addItem(submenu("Edit In", editInMenu(targets: ids)))
        let ai = NSMenu()
        for recipe in AIRecipe.allCases {
            ai.addItem(actions.menuItem(AtelierAction.ai, RecipeParameters(recipe: recipe.rawValue),
                                        title: "\(recipe.title)…", enabled: ids.count == 1, targets: ids))
        }
        menu.addItem(submenu("AI", ai))

        if includeZoom {
            menu.addItem(.separator())
            for choice in ZoomChoice.allCases {
                let level = ZoomLevel(choice)
                let title = level == .fit ? "Zoom to Fit" : level == .fill ? "Zoom to Fill" : "Zoom to \(level.label)"
                menu.addItem(actions.menuItem(AtelierAction.setZoom, ZoomParameters(level: choice), title: title,
                                              checked: zoom == level, targets: ids))
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(AtelierAction.showInFinder))

        menu.addItem(.separator())
        let rating = NSMenu()
        for stars in 0...5 {
            let title = stars == 0 ? "None" : String(repeating: "★", count: stars)
            rating.addItem(actions.menuItem(AtelierAction.setRating, RatingParameters(stars: stars), title: title,
                                            checked: detail?.metadata.rating == stars, targets: ids))
        }
        menu.addItem(submenu("Set Rating", rating))

        let flag = NSMenu()
        let flags: [(String, Flag, FlagChoice)] = [("Picked", .picked, .picked), ("Rejected", .rejected, .rejected),
                                                   ("Unflagged", .none, .unflagged)]
        for (title, value, choice) in flags {
            flag.addItem(actions.menuItem(AtelierAction.setFlag, FlagParameters(flag: choice), title: title,
                                          checked: detail?.metadata.flag == value, targets: ids))
        }
        menu.addItem(submenu("Set Flag", flag))

        let label = NSMenu()
        for value in ColorLabel.allCases {
            label.addItem(actions.menuItem(AtelierAction.toggleLabel, LabelParameters(label: value.choice),
                                           title: value.rawValue, checked: detail?.metadata.colorLabel == value,
                                           targets: ids))
        }
        menu.addItem(submenu("Set Color Label", label))

        menu.addItem(.separator())
        let develop = NSMenu()
        develop.addItem(item(AtelierAction.copySettings, enabled: ids.count == 1))
        develop.addItem(item(AtelierAction.pasteSettings, "Paste Settings\(count)", enabled: self.develop.clipboard != nil))
        develop.addItem(.separator())
        develop.addItem(item(AtelierAction.resetSettings, "Reset All Settings\(count)"))
        menu.addItem(submenu("Develop Settings", develop))

        // Recent, then one submenu per group, the user's groups first, as in the Presets panel.
        let presets = NSMenu()
        func presetItem(_ preset: DevelopPreset) -> NSMenuItem {
            actions.menuItem(AtelierAction.applyPreset, PresetParameters(preset: preset.id), title: preset.name, targets: ids)
        }
        let recent = self.develop.recentPresets
        if !recent.isEmpty {
            let menu = NSMenu()
            for preset in recent {
                menu.addItem(presetItem(preset))
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
            groupMenu?.addItem(presetItem(preset))
        }
        menu.addItem(submenu("Apply Develop Preset\(count)", presets))
        menu.addItem(item(AtelierAction.matchLook, enabled: matchProgress == nil))

        if !sidebar.collections.isEmpty {
            let collections = NSMenu()
            for collection in sidebar.collections {
                guard let id = collection.id else { continue }
                collections.addItem(actions.menuItem(AtelierAction.addToCollection, CollectionParameters(collection: id),
                                                     title: collection.name, targets: ids))
            }
            menu.addItem(submenu("Add to Collection", collections))
        }
        if case .collection = sidebarSelection {
            menu.addItem(item(AtelierAction.removeFromCollection))
        }
        if case .importGroup = sidebarSelection {
            menu.addItem(item(AtelierAction.removeFromImport))
        }

        menu.addItem(.separator())
        menu.addItem(item(AtelierAction.writeXMP, "Write XMP Metadata"))
        menu.addItem(item(AtelierAction.export, "Export\(count)…"))

        menu.addItem(.separator())
        menu.addItem(item(AtelierAction.removePhoto, ids.count > 1 ? "Remove \(ids.count) Photos…" : "Remove Photo…"))
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
    func editInMenu(targets ids: [Int64]? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for editor in externalEditors {
            let item = actions.menuItem(AtelierAction.editIn, EditorParameters(editor: editor.appPath),
                                        title: "Edit in \(editor.name)", targets: ids)
            let icon = editor.icon
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !externalEditors.isEmpty { menu.addItem(.separator()) }
        menu.addItem(actions.menuItem(AtelierAction.editInOther, targets: ids))
        return menu
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")  // not an action: a submenu heading
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
