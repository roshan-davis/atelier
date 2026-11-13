import AgentActions
import AppKit
import AtelierActions
import AtelierCore

/// Atelier's action registry: every menu bar item, key command and right-click photo item runs
/// through here (AT-050a). Each handler gets its photo ids already resolved: from the selection
/// (`targetIDs`) when the person runs it, or the ids the right-click menu was built for.
///
/// A new command is an `AtelierAction` plus a `bind` here; the menus then build it with
/// `actions.button`, `actions.toggle` or `actions.menuItem`. AtelierAppTests check that every
/// catalog action is bound.
typealias AtelierRegistry = ActionRegistry<LibraryModel, Int64>

extension LibraryModel {
    func makeActionRegistry() -> AtelierRegistry {
        let registry = AtelierRegistry(catalog: AtelierAction.catalog, context: self) { model, kind in
            kind == .photos ? model.targetIDs : []
        }
        Self.bindFile(registry)
        Self.bindView(registry)
        Self.bindLibrary(registry)
        Self.bindPhoto(registry)
        Self.bindDevelop(registry)
        return registry
    }

    /// Runs `body` with `ids` as the targets. From the menus and keys `ids` already are the
    /// targets, so this changes nothing; it lets handlers that still read `targetIDs` act on
    /// named photos (agents, AT-050b onward).
    func withTargets(_ ids: [Int64], _ body: () -> Void) {
        guard ids != targetIDs else { return body() }
        let saved = menuTargets
        menuTargets = ids
        body()
        menuTargets = saved
    }

    private static func bindFile(_ r: AtelierRegistry) {
        r.bind(AtelierAction.importPhotos) { model, _, _ in model.beginImport() }
        r.bind(AtelierAction.export) { model, _, ids in model.withTargets(ids) { model.beginExport() } }
        // ⌘S saves in HDR mode; elsewhere it stays Library > Write XMP for Selection.
        r.bind(AtelierAction.saveHDR,
               enabled: { $0.mode == .hdr && $0.hdr.hasPhoto && !$0.hdr.busy },
               shortcutWhen: { $0.mode == .hdr }) { model, _, _ in model.hdr.save() }
        r.bind(AtelierAction.saveHDRAsNew,
               enabled: { $0.mode == .hdr && $0.hdr.hasPhoto && !$0.hdr.busy }) { model, _, _ in
            model.hdr.save(asNew: true)
        }
        r.bind(AtelierAction.undo) { model, _, _ in model.undo() }
        r.bind(AtelierAction.redo) { model, _, _ in model.redo() }
        r.bind(AtelierAction.keyboardShortcuts) { model, _, _ in model.showingShortcuts = true }
    }

    private static func bindView(_ r: AtelierRegistry) {
        r.bind(AtelierAction.zoomIn) { model, _, _ in model.zoomIn() }
        r.bind(AtelierAction.zoomOut) { model, _, _ in model.zoomOut() }
        r.bind(AtelierAction.zoomToFit) { model, _, _ in model.zoom = .fit }
        r.bind(AtelierAction.zoomTo100) { model, _, _ in model.zoom = .percent(100) }
        r.bind(AtelierAction.toggleZoom) { model, _, _ in model.toggleZoom() }
        r.bind(AtelierAction.setZoom) { model, parameters, _ in model.zoom = ZoomLevel(parameters.level) }
        r.bind(AtelierAction.showFilmstrip, isOn: { _ in Filmstrip.isVisible }) { _, _, _ in
            Filmstrip.isVisible.toggle()
        }
        // Leaving Hide asks for Touch ID or the login password (see PrivatePhotos).
        r.bind(AtelierAction.privatePhotos) { model, parameters, _ in
            model.privatePhotos.choose(PrivateVisibility(parameters.visibility))
        }
        r.bind(AtelierAction.frameDiagnostics, enabled: { $0.mode == .develop },
               isOn: { _ in UserDefaults.standard.bool(forKey: DevelopFrameHUD.preference) }) { _, _, _ in
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: DevelopFrameHUD.preference), forKey: DevelopFrameHUD.preference)
        }
        r.bindChecked(AtelierAction.nextArea) { model, _, _ in
            guard model.usesPanelKeys else { return false }
            KeyboardFocus.shared.cycle(forward: true)
            return true
        }
        r.bindChecked(AtelierAction.previousArea) { model, _, _ in
            guard model.usesPanelKeys else { return false }
            KeyboardFocus.shared.cycle(forward: false)
            return true
        }
    }

    private static func bindLibrary(_ r: AtelierRegistry) {
        r.bind(AtelierAction.grid) { model, _, _ in model.mode = .grid }
        r.bind(AtelierAction.loupe) { model, _, _ in model.openLoupe() }
        r.bind(AtelierAction.develop) { model, _, _ in model.openDevelop() }
        r.bind(AtelierAction.cullImport, enabled: { model in
            if case .importGroup = model.sidebarSelection { return true } else { return false }
        }) { model, _, _ in
            if case .importGroup(let id) = model.sidebarSelection { model.beginCull(importGroup: id) }
        }
        r.bind(AtelierAction.writeXMP, shortcutWhen: { $0.mode != .hdr }) { model, _, ids in
            model.withTargets(ids) { model.writeXMP(selectionOnly: true) }
        }
        r.bind(AtelierAction.writeAllXMP) { model, _, _ in model.writeXMP(selectionOnly: false) }
        r.bind(AtelierAction.refreshVolumes) { model, _, _ in model.refreshVolumes() }
    }

    private static func bindPhoto(_ r: AtelierRegistry) {
        r.bind(AtelierAction.createVirtualCopy, enabled: { $0.focusedID != nil }) { model, _, ids in
            model.withTargets(ids) { model.createVirtualCopies() }
        }
        r.bind(AtelierAction.removeVirtualCopy, enabled: { $0.targetsIncludeVirtualCopy }) { model, _, ids in
            model.withTargets(ids) { model.removeVirtualCopies() }
        }
        r.bind(AtelierAction.removePhoto, enabled: { !$0.targetIDs.isEmpty }) { model, _, ids in
            model.withTargets(ids) { model.beginRemovePhotos() }
        }
        r.bind(AtelierAction.showCullGroup, enabled: { $0.focusedCullGroupSize >= 2 }) { model, _, _ in
            model.showCullGroup()
        }
        r.bind(AtelierAction.hdr, enabled: { $0.targetIDs.count == 1 }) { model, _, ids in
            model.withTargets(ids) { model.openHDR() }
        }
        r.bind(AtelierAction.editIn, enabled: { $0.focusedID != nil }) { model, parameters, ids in
            guard let editor = model.externalEditors.first(where: { $0.appPath == parameters.editor }) else { return }
            model.withTargets(ids) { model.editIn(editor) }
        }
        r.bind(AtelierAction.editInOther, enabled: { $0.focusedID != nil }) { model, _, ids in
            model.withTargets(ids) { model.editInOtherApp() }
        }
        // In Develop the target is the open photo, so this is the menu bar's beginMatchLook();
        // from the right-click menu it opens the clicked photos in Develop first.
        r.bind(AtelierAction.matchLook, enabled: { $0.mode == .develop && $0.focusedID != nil }) { model, _, ids in
            model.beginMatchLook(for: ids)
        }
        r.bind(AtelierAction.ai, enabled: { $0.focusedID != nil }) { model, parameters, _ in
            guard let recipe = AIRecipe(rawValue: parameters.recipe) else { return }
            model.openAI(recipe)
        }
        r.bind(AtelierAction.showInFinder) { model, _, ids in model.withTargets(ids) { model.showInFinder() } }
        r.bind(AtelierAction.setRating) { model, parameters, ids in model.setRating(parameters.stars, for: ids) }
        r.bind(AtelierAction.setFlag) { model, parameters, ids in model.setFlag(Flag(parameters.flag), for: ids) }
        r.bind(AtelierAction.toggleLabel) { model, parameters, ids in
            model.toggleLabel(ColorLabel(parameters.label), for: ids)
        }
        r.bind(AtelierAction.addToCollection) { model, parameters, ids in
            model.addAssets(ids, toCollection: parameters.collection)
        }
        r.bind(AtelierAction.removeFromCollection) { model, _, ids in
            model.withTargets(ids) { model.removeSelectionFromCurrentCollection() }
        }
        r.bind(AtelierAction.removeFromImport) { model, _, ids in
            model.withTargets(ids) { model.removeSelectionFromCurrentImport() }
        }
        r.bind(AtelierAction.resetSettings) { model, _, ids in model.develop.resetSettings(of: ids) }
    }

    private static func bindDevelop(_ r: AtelierRegistry) {
        r.bind(AtelierAction.copySettings) { model, _, _ in model.copyDevelopSettings() }
        r.bind(AtelierAction.pasteSettings) { model, _, ids in model.develop.pasteSettings(onto: ids) }
        r.bind(AtelierAction.resetAll, enabled: { $0.mode == .develop }) { model, _, _ in model.develop.resetAll() }
        r.bind(AtelierAction.autoWhiteBalance, enabled: { $0.mode == .develop && $0.develop.assetID != nil }) { model, _, _ in
            model.develop.findWhiteBalance()
        }
        r.bindChecked(AtelierAction.whiteBalanceSelector, enabled: { $0.focusedID != nil }) { model, _, _ in
            if model.mode != .develop { model.openDevelop() }
            guard model.mode == .develop, model.develop.assetID != nil else { return false }
            model.develop.isPickingWhiteBalance.toggle()
            return true
        }
        r.bindChecked(AtelierAction.crop, enabled: { $0.focusedID != nil }) { model, _, _ in
            if model.mode != .develop { model.openDevelop() }
            guard model.mode == .develop else { return false }
            model.develop.isCropping.toggle()
            return true
        }
        r.bind(AtelierAction.rotateLeft, enabled: { $0.mode == .develop }) { model, _, _ in model.rotate(clockwise: false) }
        r.bind(AtelierAction.rotateRight, enabled: { $0.mode == .develop }) { model, _, _ in model.rotate(clockwise: true) }
        r.bindChecked(AtelierAction.showBefore, enabled: { $0.mode == .develop }) { model, _, _ in
            if model.mode == .hdr, model.hdr.hasPhoto { model.hdr.showingBefore.toggle(); return true }
            guard model.mode == .develop else { return false }
            model.develop.showingBefore.toggle()
            return true
        }
        r.bindChecked(AtelierAction.showClipping, enabled: { $0.mode == .develop && $0.develop.assetID != nil }) { model, _, _ in
            guard model.mode == .develop, model.develop.assetID != nil else { return false }
            model.develop.toggleClippingOverlay()
            return true
        }
        r.bind(AtelierAction.compareMode, enabled: { $0.mode == .develop }) { model, parameters, _ in
            if let mode = CompareMode(rawValue: parameters.mode.rawValue) { model.develop.compareMode = mode }
        }
        r.bindChecked(AtelierAction.cycleCompareMode) { model, _, _ in
            if model.mode == .hdr, model.hdr.hasPhoto { model.hdr.cycleCompareMode(); return true }
            guard model.mode == .develop else { return false }
            model.develop.cycleCompareMode()
            return true
        }
        r.bind(AtelierAction.newPreset, enabled: { $0.mode == .develop && $0.develop.assetID != nil }) { model, _, _ in
            model.develop.showingNewPreset = true
        }
        r.bind(AtelierAction.managePresets, enabled: { $0.mode == .develop }) { model, _, _ in
            model.develop.showingManagePresets = true
        }
        r.bindChecked(AtelierAction.applyPreset) { model, parameters, ids in
            guard let preset = model.develop.visiblePresets.first(where: { $0.id == parameters.preset }) else { return false }
            model.develop.applyPreset(preset, onto: ids)
            return true
        }
        r.bindChecked(AtelierAction.blackAndWhite) { model, _, _ in
            guard model.mode == .develop, model.develop.assetID != nil else { return false }
            model.develop.setMonochrome(!model.develop.settings.monochrome)
            return true
        }
        r.bindChecked(AtelierAction.masking) { model, _, _ in
            if model.mode != .develop { model.openDevelop() }
            guard model.mode == .develop else { return false }
            model.develop.isMasking.toggle()
            return true
        }
        r.bindChecked(AtelierAction.linearGradient) { model, _, _ in model.startMaskTool(.linear) }
        r.bindChecked(AtelierAction.radialGradient) { model, _, _ in model.startMaskTool(.radial) }
        r.bindChecked(AtelierAction.brush) { model, _, _ in model.startMaskTool(.brush) }
        r.bindChecked(AtelierAction.maskOverlay) { model, _, _ in
            guard model.mode == .develop, model.develop.isMasking else { return false }
            model.develop.showMaskOverlay.toggle()
            return true
        }
        r.bindChecked(AtelierAction.guidedUpright) { model, _, _ in
            guard model.mode == .develop else { return false }
            if model.develop.isGuiding { model.develop.isGuiding = false } else { model.develop.setUpright(.guided) }
            return true
        }
    }
}

private extension LibraryModel {
    func startMaskTool(_ tool: DevelopSettings.MaskComponent.Kind) -> Bool {
        if mode != .develop { openDevelop() }
        guard mode == .develop else { return false }
        develop.startMaskTool(tool)
        return true
    }
}

// MARK: - Mapping the catalog's parameter types to Atelier's

extension ZoomLevel {
    init(_ choice: ZoomChoice) {
        switch choice {
        case .fit: self = .fit
        case .fill: self = .fill
        case .percent100: self = .percent(100)
        case .percent200: self = .percent(200)
        }
    }
}

extension Flag {
    init(_ choice: FlagChoice) {
        switch choice {
        case .picked: self = .picked
        case .rejected: self = .rejected
        case .unflagged: self = .none
        }
    }
}

extension ColorLabel {
    init(_ choice: LabelChoice) {
        switch choice {
        case .red: self = .red
        case .yellow: self = .yellow
        case .green: self = .green
        case .blue: self = .blue
        case .purple: self = .purple
        }
    }

    var choice: LabelChoice {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

extension PrivateVisibility {
    init(_ choice: PrivacyChoice) {
        switch choice {
        case .hidden: self = .hidden
        case .shown: self = .shown
        case .only: self = .only
        }
    }

    var choice: PrivacyChoice {
        switch self {
        case .hidden: return .hidden
        case .shown: return .shown
        case .only: return .only
        }
    }
}

// MARK: - Keys

extension KeyAction {
    /// The registry action this key runs. `.reject` in the crop tool is handled before this
    /// (it switches the crop's orientation, as in Lightroom).
    @MainActor
    func run(in registry: AtelierRegistry) -> Bool {
        switch self {
        case .rating0: return registry.run(AtelierAction.setRating, RatingParameters(stars: 0))
        case .rating1: return registry.run(AtelierAction.setRating, RatingParameters(stars: 1))
        case .rating2: return registry.run(AtelierAction.setRating, RatingParameters(stars: 2))
        case .rating3: return registry.run(AtelierAction.setRating, RatingParameters(stars: 3))
        case .rating4: return registry.run(AtelierAction.setRating, RatingParameters(stars: 4))
        case .rating5: return registry.run(AtelierAction.setRating, RatingParameters(stars: 5))
        case .labelRed: return registry.run(AtelierAction.toggleLabel, LabelParameters(label: .red))
        case .labelYellow: return registry.run(AtelierAction.toggleLabel, LabelParameters(label: .yellow))
        case .labelGreen: return registry.run(AtelierAction.toggleLabel, LabelParameters(label: .green))
        case .labelBlue: return registry.run(AtelierAction.toggleLabel, LabelParameters(label: .blue))
        case .pick: return registry.run(AtelierAction.setFlag, FlagParameters(flag: .picked))
        case .reject: return registry.run(AtelierAction.setFlag, FlagParameters(flag: .rejected))
        case .unflag: return registry.run(AtelierAction.setFlag, FlagParameters(flag: .unflagged))
        case .grid: return registry.run(AtelierAction.grid)
        case .loupe: return registry.run(AtelierAction.loupe)
        case .develop: return registry.run(AtelierAction.develop)
        case .beforeAfter: return registry.run(AtelierAction.showBefore)
        case .compareMode: return registry.run(AtelierAction.cycleCompareMode)
        case .zoom: return registry.run(AtelierAction.toggleZoom)
        case .crop: return registry.run(AtelierAction.crop)
        case .treatment: return registry.run(AtelierAction.blackAndWhite)
        case .whiteBalance: return registry.run(AtelierAction.whiteBalanceSelector)
        case .linearGradient: return registry.run(AtelierAction.linearGradient)
        case .brush: return registry.run(AtelierAction.brush)
        case .maskOverlay: return registry.run(AtelierAction.maskOverlay)
        case .clipping: return registry.run(AtelierAction.showClipping)
        case .masking: return registry.run(AtelierAction.masking)
        case .radialGradient: return registry.run(AtelierAction.radialGradient)
        case .guidedUpright: return registry.run(AtelierAction.guidedUpright)
        case .nextArea: return registry.run(AtelierAction.nextArea)
        case .previousArea: return registry.run(AtelierAction.previousArea)
        }
    }
}
