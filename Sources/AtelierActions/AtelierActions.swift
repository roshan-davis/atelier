import AgentActions

/// Every Atelier command: the menu bar, the keys in Settings > Keyboard and the right-click photo
/// menu are all built from these, and agents (from AT-050b) see the same list. Adding one here
/// and binding it in `LibraryModel+Actions.swift` puts it everywhere at once; the committed
/// Docs/agent-actions-catalog.json shows the change in the PR.
///
/// Kinds decide what agents may do (see `ActionKind.tier`). Exposed by default; hide one only
/// with a reason a person would accept.
public enum AtelierAction {
    // MARK: File

    public static let importPhotos = Action<NoParameters>(
        "file.importPhotos", "Import Photos…", place: "File > Import Photos…",
        summary: "Opens the import dialog, where the person picks sources and how to import.",
        kind: .writesFiles, shortcut: KeyShortcut("i", [.command, .shift]))
    public static let export = Action<NoParameters>(
        "file.export", "Export…", place: "File > Export…",
        summary: "Opens the export dialog for the selected photos.",
        kind: .writesFiles, targets: .photos, shortcut: KeyShortcut("e", [.command, .shift]))
    public static let saveHDR = Action<NoParameters>(
        "file.saveHDR", "Save HDR", place: "File > Save HDR",
        summary: "Saves the HDR edit in HDR mode.",
        kind: .writesFiles, shortcut: KeyShortcut("s"))
    public static let saveHDRAsNew = Action<NoParameters>(
        "file.saveHDRAsNew", "Save HDR As New…", place: "File > Save HDR As New…",
        summary: "Saves the HDR edit as a new photo.",
        kind: .writesFiles, shortcut: KeyShortcut("s", [.command, .shift]))

    // MARK: Edit

    public static let undo = Action<NoParameters>(
        "edit.undo", "Undo", place: "Edit > Undo",
        summary: "Steps back through the open photo's Develop or HDR history.",
        kind: .edit, shortcut: KeyShortcut("z"),
        hidden: "The person's own Undo. Agents undo only their own change (undo_change, AT-050d).")
    public static let redo = Action<NoParameters>(
        "edit.redo", "Redo", place: "Edit > Redo",
        summary: "Steps forward through the open photo's Develop or HDR history.",
        kind: .edit, shortcut: KeyShortcut("z", [.command, .shift]),
        hidden: "The person's own Redo. Agents undo only their own change (undo_change, AT-050d).")

    // MARK: View

    public static let zoomIn = Action<NoParameters>(
        "view.zoomIn", "Zoom In", place: "View > Zoom In",
        summary: "Zooms in on the photo.", kind: .view, shortcut: KeyShortcut("="))
    public static let zoomOut = Action<NoParameters>(
        "view.zoomOut", "Zoom Out", place: "View > Zoom Out",
        summary: "Zooms out of the photo.", kind: .view, shortcut: KeyShortcut("-"))
    public static let zoomToFit = Action<NoParameters>(
        "view.zoomToFit", "Zoom to Fit", place: "View > Zoom to Fit",
        summary: "Shows the whole photo.", kind: .view, shortcut: KeyShortcut("0"))
    public static let zoomTo100 = Action<NoParameters>(
        "view.zoomTo100", "Zoom to 100%", place: "View > Zoom to 100%",
        summary: "Shows the photo at 100%.", kind: .view, shortcut: KeyShortcut("1", [.command, .option]))
    public static let toggleZoom = Action<NoParameters>(
        "view.toggleZoom", "Toggle Zoom (Z)", place: "View > Toggle Zoom (Z), key Z",
        summary: "Switches between Fit and the click zoom; from the grid, opens the photo in Loupe.", kind: .view)
    public static let setZoom = Action<ZoomParameters>(
        "view.setZoom", "Zoom", place: "Photo menu > Zoom to Fit, Fill, 100%, 200%",
        summary: "Sets the zoom of the open photo.", kind: .view)
    public static let showFilmstrip = Action<NoParameters>(
        "view.showFilmstrip", "Show Filmstrip", place: "View > Show Filmstrip",
        summary: "Shows or hides the Filmstrip.", kind: .view, shortcut: KeyShortcut("F6", []))
    public static let showNotes = Action<NoParameters>(
        "view.showNotes", "Show Notes", place: "View > Show Notes",
        summary: "Shows or hides the sticky notes panel over the photo (AT-058).", kind: .view,
        shortcut: KeyShortcut("n", [.command, .option]))
    public static let privatePhotos = Action<PrivacyParameters>(
        "view.privatePhotos", "Private Photos", place: "View > Hide, Show, Show Only Private Photos",
        summary: "Hides or shows private imports and collections.", kind: .view,
        hidden: "Showing private photos asks for Touch ID or the login password; only the person may do that.")

    // MARK: Library

    public static let grid = Action<NoParameters>(
        "library.grid", "Grid", place: "Library > Grid, key G",
        summary: "Shows the photos as a grid.", kind: .view, shortcut: KeyShortcut("g"))
    public static let loupe = Action<NoParameters>(
        "library.loupe", "Loupe", place: "Library > Loupe, key E, photo menu > Open in Loupe",
        summary: "Shows the focused photo large.", kind: .view, shortcut: KeyShortcut("e"))
    public static let develop = Action<NoParameters>(
        "library.develop", "Develop", place: "Library > Develop, key D, photo menu > Edit in Develop",
        summary: "Opens the focused photo in Develop.", kind: .view, shortcut: KeyShortcut("d"))
    public static let cullImport = Action<NoParameters>(
        "library.cullImport", "Cull Import…", place: "Library > Cull Import…",
        summary: "Starts culling the import selected in the sidebar.", kind: .view)
    public static let writeXMP = Action<NoParameters>(
        "library.writeXMP", "Write XMP for Selection", place: "Library > Write XMP for Selection, photo menu > Write XMP Metadata",
        summary: "Writes XMP sidecars for the selected photos.",
        kind: .writesFiles, targets: .photos, shortcut: KeyShortcut("s"))
    public static let writeAllXMP = Action<NoParameters>(
        "library.writeAllXMP", "Write All Unsaved XMP", place: "Library > Write All Unsaved XMP",
        summary: "Writes XMP sidecars for every photo with unsaved changes.",
        kind: .writesFiles, shortcut: KeyShortcut("s", [.command, .option]))
    public static let refreshVolumes = Action<NoParameters>(
        "library.refreshVolumes", "Refresh Volumes", place: "Library > Refresh Volumes",
        summary: "Checks which drives are connected and retries photos that couldn't be read.",
        kind: .reads, shortcut: KeyShortcut("r"))

    // MARK: Photo

    public static let createVirtualCopy = Action<NoParameters>(
        "photo.createVirtualCopy", "Create Virtual Copy", place: "Photo > Create Virtual Copy, photo menu",
        summary: "Adds a virtual copy of each photo, with its own Develop settings.",
        kind: .edit, targets: .photos, shortcut: KeyShortcut("'"))
    public static let removeVirtualCopy = Action<NoParameters>(
        "photo.removeVirtualCopy", "Remove Virtual Copy…", place: "Photo > Remove Virtual Copy…, photo menu",
        summary: "Asks, then removes the selected virtual copies.", kind: .deletes, targets: .photos)
    public static let removePhoto = Action<NoParameters>(
        "photo.remove", "Remove Photo…", place: "Photo > Remove Photo… (Delete), photo menu",
        summary: "Asks, then removes the photos from the catalog or moves them to the Trash.",
        kind: .deletes, targets: .photos)
    public static let addNote = Action<NoParameters>(
        "photo.addNote", "Add Note…", place: "Photo > Add Note…, photo menu",
        summary: "Opens a new note to type on the photo; the text also goes to the other selected photos.",
        kind: .edit, targets: .photos, shortcut: KeyShortcut("n", [.command, .option, .shift]),
        hidden: "Opens a note for the person to type in; agents add notes with set_metadata's add_note.")
    public static let showCullGroup = Action<NoParameters>(
        "photo.showCullGroup", "Show Cull Group", place: "Photo > Show Cull Group, photo menu",
        summary: "Shows the other shots of the focused photo's burst or similar group.",
        kind: .view, shortcut: KeyShortcut("g", [.command, .shift]))
    public static let hdr = Action<NoParameters>(
        "photo.hdr", "HDR…", place: "Photo > HDR…, photo menu > Edit in HDR",
        summary: "Opens one photo in HDR mode.",
        kind: .view, targets: .photos, shortcut: KeyShortcut("h", [.control]))
    public static let editIn = Action<EditorParameters>(
        "photo.editIn", "Edit In", place: "Photo > Edit In, photo menu > Edit In",
        summary: "Renders the photo and opens it in another app; the edit comes back as a new photo.",
        kind: .opensApp, targets: .photos, shortcut: KeyShortcut("e", [.command, .option]))
    public static let editInOther = Action<NoParameters>(
        "photo.editInOther", "Other Application…", place: "Photo > Edit In > Other Application…",
        summary: "Asks the person for an app, then opens the photo in it.", kind: .opensApp, targets: .photos)
    public static let matchLook = Action<NoParameters>(
        "photo.matchLook", "Match Look to Reference…", place: "Photo > Match Look to Reference…, photo menu",
        summary: "Opens Match Look for the photo (Photo menu: the open photo in Develop; right-click: the clicked photos).",
        kind: .edit, targets: .photos, shortcut: KeyShortcut("m", [.command, .shift]))
    public static let ai = Action<RecipeParameters>(
        "photo.ai", "AI", place: "Photo > Remove Object…, Replace Background…, Upscale…, photo menu > AI",
        summary: "Opens Develop with the AI tool set to that recipe; nothing runs until the person starts it.",
        kind: .view)
    public static let showInFinder = Action<NoParameters>(
        "photo.showInFinder", "Show in Finder", place: "Photo menu > Show in Finder",
        summary: "Shows the originals in Finder.", kind: .opensApp, targets: .photos)
    public static let setRating = Action<RatingParameters>(
        "photo.setRating", "Set Rating", place: "Photo menu > Set Rating, keys 0 to 5",
        summary: "Sets the star rating; a RAW's hidden JPEG follows it.", kind: .edit, targets: .photos)
    public static let setFlag = Action<FlagParameters>(
        "photo.setFlag", "Set Flag", place: "Photo menu > Set Flag, keys P, X, U",
        summary: "Flags the photos as picked or rejected, or removes the flag.", kind: .edit, targets: .photos)
    public static let toggleLabel = Action<LabelParameters>(
        "photo.toggleLabel", "Set Color Label", place: "Photo menu > Set Color Label, keys 6 to 9",
        summary: "Turns a color label on or off.", kind: .edit, targets: .photos)
    public static let addToCollection = Action<CollectionParameters>(
        "photo.addToCollection", "Add to Collection", place: "Photo menu > Add to Collection",
        summary: "Adds the photos to a collection.", kind: .edit, targets: .photos)
    public static let removeFromCollection = Action<NoParameters>(
        "photo.removeFromCollection", "Remove from This Collection", place: "Photo menu > Remove from This Collection",
        summary: "Takes the photos out of the collection shown in the sidebar; the photos stay in the catalog.",
        kind: .deletes, targets: .photos)
    public static let removeFromImport = Action<NoParameters>(
        "photo.removeFromImport", "Remove from This Import", place: "Photo menu > Remove from This Import",
        summary: "Takes the photos out of the import shown in the sidebar; the photos stay in the catalog.",
        kind: .deletes, targets: .photos)
    public static let resetSettings = Action<NoParameters>(
        "photo.resetSettings", "Reset All Settings", place: "Photo menu > Develop Settings > Reset All Settings",
        summary: "Resets every Develop setting of the photos.", kind: .edit, targets: .photos)

    // MARK: Develop

    public static let frameDiagnostics = Action<NoParameters>(
        "develop.frameDiagnostics", "Frame Diagnostics", place: "Develop > Frame Diagnostics",
        summary: "Shows or hides the frame timing readout.", kind: .view,
        hidden: "A performance readout for people checking slider smoothness.")
    public static let copySettings = Action<NoParameters>(
        "develop.copySettings", "Copy Settings", place: "Develop > Copy Settings, photo menu",
        summary: "Copies the focused photo's Develop settings.", kind: .reads, shortcut: KeyShortcut("c", [.command, .shift]))
    public static let pasteSettings = Action<NoParameters>(
        "develop.pasteSettings", "Paste Settings", place: "Develop > Paste Settings, photo menu",
        summary: "Pastes the copied Develop settings onto the photos.",
        kind: .edit, targets: .photos, shortcut: KeyShortcut("v", [.command, .shift]))
    public static let resetAll = Action<NoParameters>(
        "develop.resetAll", "Reset All Settings", place: "Develop > Reset All Settings",
        summary: "Resets every Develop setting of the open photo.", kind: .edit, shortcut: KeyShortcut("r", [.command, .shift]))
    public static let autoWhiteBalance = Action<NoParameters>(
        "develop.autoWhiteBalance", "Auto White Balance", place: "Develop > Auto White Balance",
        summary: "Sets the open photo's white balance automatically.",
        kind: .edit, shortcut: KeyShortcut("u", [.command, .shift]))
    public static let whiteBalanceSelector = Action<NoParameters>(
        "develop.whiteBalanceSelector", "White Balance Selector (W)", place: "Develop > White Balance Selector (W), key W",
        summary: "Picks up or puts away the white balance eyedropper.", kind: .view)
    public static let crop = Action<NoParameters>(
        "develop.crop", "Crop & Straighten (R)", place: "Develop > Crop & Straighten (R), key R",
        summary: "Opens or closes the crop tool.", kind: .view)
    public static let rotateLeft = Action<NoParameters>(
        "develop.rotateLeft", "Rotate Left", place: "Develop > Rotate Left",
        summary: "Turns the open photo 90° counterclockwise.", kind: .edit, shortcut: KeyShortcut("["))
    public static let rotateRight = Action<NoParameters>(
        "develop.rotateRight", "Rotate Right", place: "Develop > Rotate Right",
        summary: "Turns the open photo 90° clockwise.", kind: .edit, shortcut: KeyShortcut("]"))
    public static let showBefore = Action<NoParameters>(
        "develop.showBefore", "Show Before (\\)", place: "Develop > Show Before (\\), key \\",
        summary: "Shows the photo without its edits, or with them again (Develop and HDR).", kind: .view)
    public static let showClipping = Action<NoParameters>(
        "develop.showClipping", "Show Clipping (J)", place: "Develop > Show Clipping (J), key J",
        summary: "Shows or hides clipped highlights and shadows on the photo.", kind: .view)
    public static let compareMode = Action<CompareParameters>(
        "develop.compareMode", "Before and After (Y)", place: "Develop > Before and After (Y)",
        summary: "Sets the before and after view.", kind: .view)
    public static let cycleCompareMode = Action<NoParameters>(
        "develop.cycleCompareMode", "Before and After: next view", place: "Key Y",
        summary: "Moves to the next before and after view: off, side by side, slider (Develop and HDR).", kind: .view)
    public static let newPreset = Action<NoParameters>(
        "develop.newPreset", "New Preset…", place: "Develop > New Preset…",
        summary: "Opens the dialog to save the open photo's settings as a preset.",
        kind: .edit, shortcut: KeyShortcut("n", [.command, .shift]))
    public static let managePresets = Action<NoParameters>(
        "develop.managePresets", "Manage Presets…", place: "Develop > Manage Presets…",
        summary: "Opens the preset manager.", kind: .view)
    public static let applyPreset = Action<PresetParameters>(
        "develop.applyPreset", "Apply Develop Preset", place: "Photo menu > Apply Develop Preset",
        summary: "Applies a Develop preset to the photos.", kind: .edit, targets: .photos)
    public static let blackAndWhite = Action<NoParameters>(
        "develop.blackAndWhite", "Black & White", place: "Key V",
        summary: "Switches the open photo between color and black and white.", kind: .edit)
    public static let masking = Action<NoParameters>(
        "develop.masking", "Masking", place: "Key ⇧W",
        summary: "Opens or closes Masking.", kind: .view)
    public static let linearGradient = Action<NoParameters>(
        "develop.linearGradient", "Masking: Linear Gradient", place: "Key M",
        summary: "Starts a Linear Gradient mask.", kind: .view)
    public static let radialGradient = Action<NoParameters>(
        "develop.radialGradient", "Masking: Radial Gradient", place: "Key ⇧M",
        summary: "Starts a Radial Gradient mask.", kind: .view)
    public static let brush = Action<NoParameters>(
        "develop.brush", "Masking: Brush", place: "Key K",
        summary: "Starts a Brush mask.", kind: .view)
    public static let maskOverlay = Action<NoParameters>(
        "develop.maskOverlay", "Masking: Show Overlay", place: "Key O",
        summary: "Shows or hides the mask overlay.", kind: .view)
    public static let guidedUpright = Action<NoParameters>(
        "develop.guidedUpright", "Transform: Guided Upright", place: "Key ⇧T",
        summary: "Opens or closes Guided Upright.", kind: .view)

    // MARK: Keyboard focus

    public static let nextArea = Action<NoParameters>(
        "focus.nextArea", "Focus: Next Area", place: "Key ⌃Tab",
        summary: "Moves keyboard focus to the next area (Presets, right panel, Filmstrip).", kind: .view,
        hidden: "Moves the keyboard focus, which means nothing without a keyboard.")
    public static let previousArea = Action<NoParameters>(
        "focus.previousArea", "Focus: Previous Area", place: "Key ⌃⇧Tab",
        summary: "Moves keyboard focus to the previous area.", kind: .view,
        hidden: "Moves the keyboard focus, which means nothing without a keyboard.")

    // MARK: Help

    public static let keyboardShortcuts = Action<NoParameters>(
        "help.keyboardShortcuts", "Keyboard Shortcuts", place: "Help > Keyboard Shortcuts",
        summary: "Shows the keyboard shortcut sheet.", kind: .view, shortcut: KeyShortcut("/"),
        hidden: "Shows the person a cheat sheet of keys.")

    /// Every action, in menu order. A test fails if one declared above is missing.
    public static let all: [ActionDescriptor] = [
        importPhotos.descriptor, export.descriptor, saveHDR.descriptor, saveHDRAsNew.descriptor,
        undo.descriptor, redo.descriptor, zoomIn.descriptor, zoomOut.descriptor, zoomToFit.descriptor,
        zoomTo100.descriptor, toggleZoom.descriptor, setZoom.descriptor, showFilmstrip.descriptor,
        showNotes.descriptor, privatePhotos.descriptor, grid.descriptor, loupe.descriptor, develop.descriptor,
        cullImport.descriptor, writeXMP.descriptor, writeAllXMP.descriptor, refreshVolumes.descriptor,
        createVirtualCopy.descriptor, removeVirtualCopy.descriptor, removePhoto.descriptor,
        addNote.descriptor, showCullGroup.descriptor, hdr.descriptor, editIn.descriptor, editInOther.descriptor,
        matchLook.descriptor, ai.descriptor, showInFinder.descriptor, setRating.descriptor,
        setFlag.descriptor, toggleLabel.descriptor, addToCollection.descriptor,
        removeFromCollection.descriptor, removeFromImport.descriptor, resetSettings.descriptor,
        frameDiagnostics.descriptor, copySettings.descriptor, pasteSettings.descriptor, resetAll.descriptor,
        autoWhiteBalance.descriptor, whiteBalanceSelector.descriptor, crop.descriptor, rotateLeft.descriptor,
        rotateRight.descriptor, showBefore.descriptor, showClipping.descriptor, compareMode.descriptor,
        cycleCompareMode.descriptor, newPreset.descriptor, managePresets.descriptor, applyPreset.descriptor,
        blackAndWhite.descriptor, masking.descriptor, linearGradient.descriptor, radialGradient.descriptor,
        brush.descriptor, maskOverlay.descriptor, guidedUpright.descriptor, nextArea.descriptor,
        previousArea.descriptor, keyboardShortcuts.descriptor,
    ]

    public static let catalog = ActionCatalog(app: "Atelier", actions: all)
}
