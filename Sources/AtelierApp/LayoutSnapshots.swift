import AppKit
import ImageIO
import AtelierCore
import SwiftUI

#if DEBUG
/// Renders the main window in Develop at a few window sizes to images, so layout can be checked
/// on CI without a person at the Mac. Runs when ATELIER_SNAPSHOTS names an output folder. Debug
/// builds only (the UI checks, `Scripts/check_ui.py`, build Debug); a Release app has none of it
/// (AT-076 B2).
@MainActor
enum LayoutSnapshots {
    // 1000x584 is the window in Rosh's screenshot.
    static let sizes: [CGSize] = [CGSize(width: 1000, height: 584), CGSize(width: 1000, height: 640), CGSize(width: 1280, height: 800),
                                  CGSize(width: 1728, height: 1117)]

    static var outputFolder: URL? {
        ProcessInfo.processInfo.environment["ATELIER_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// ATELIER_SNAPSHOTS_ONLY: comma-separated snapshot groups to render instead of the whole pass.
    static var only: Set<String> {
        Set((ProcessInfo.processInfo.environment["ATELIER_SNAPSHOTS_ONLY"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Far outside every screen: snapshot windows are drawn there, never where Rosh can see them.
    static let offScreen = CGPoint(x: -40_000, y: -40_000)

    /// Called once at launch of a snapshot run: moves the library window (and any other) off
    /// screen, and keeps moving new ones there, so nothing appears on the Mac's display.
    static func hideOffScreen() {
        for window in NSApp.windows { hide(window) }
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { hide(window) }
        }
    }

    /// AppKit keeps part of a titled window (the library window) on a screen however far it is
    /// moved: on the Mac check of PR #153 its corner stayed at the display's bottom left. So a
    /// titled window is also fully transparent and takes no clicks. The borderless capture
    /// windows aren't held on screen, and `cacheDisplay` draws their views whatever the alpha.
    private static func hide(_ window: NSWindow) {
        if window.frame.origin != offScreen { window.setFrameOrigin(offScreen) }
        if window.styleMask.contains(.titled), window.alphaValue != 0 {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }

    static func run(model: LibraryModel, into folder: URL) async {
        for window in NSApp.windows { hide(window) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // This picker is independent of the snapshot catalog and fits in a standalone window.
        await capture(AnyView(BuiltInReferencePicker(selection: .furyRoadScene) { _ in }),
                      size: CGSize(width: BuiltInReferencePicker.width, height: 510),
                      to: folder.appendingPathComponent("match-look-built-in-picker.png"))
        await snapshotCatalogRecovery(into: folder)
        let sample = fixtures(in: folder).appendingPathComponent("atelier-snapshot.jpg")
        await importSamplePhoto(into: model, at: sample)
        let panels = ["histogram"] + DevelopSettings.Panel.allCases.map(\.rawValue)
        UserDefaults.standard.set(panels.joined(separator: ","), forKey: "develop.expandedPanels")
        UserDefaults.standard.removeObject(forKey: "panel.width")
        model.openDevelop()
        if model.mode != .develop { print("SNAPSHOT: no photo to open, Develop shown empty") }
        model.mode = .develop
        // Some edits, so sliders sit away from their defaults as they would on a real photo.
        for (parameter, value) in [(DevelopSettings.Parameter.exposure, 0.6), (.contrast, 25), (.dehaze, -20),
                                   (.vignette, -30), (.grain, 40),
                                   // Teal shadows, orange highlights: the pucks should sit on those hues.
                                   (.gradeShadowsHue, 200), (.gradeShadowsSat, 40),
                                   (.gradeHighlightsHue, 35), (.gradeHighlightsSat, 30)] {
            model.develop.set(parameter, to: value)
        }
        try? await Task.sleep(for: .seconds(3))
        // ATELIER_SNAPSHOTS_ONLY=lens-blur,hdr renders just those groups (a Mac check of one PR, in seconds).
        if !only.isEmpty {
            if only.contains("lens-blur") { await snapshotLensBlurMode(model: model, into: folder) }
            if only.contains("hdr") { await snapshotHDR(model: model, into: folder) }
            if only.contains("storage") { await snapshotStorage(model: model, into: folder) }
            fflush(stdout)
            exit(0)
        }
        var shots: [(String, CGSize, AnyView)] = sizes.map { size in
            ("develop-\(Int(size.width))x\(Int(size.height))", size, AnyView(ContentView().environmentObject(model)))
        }
        // The whole right panel at its default width, tall enough to show every section.
        shots.append(("panel-320x2600", CGSize(width: 320, height: 2600),
                      AnyView(DevelopPanel(develop: model.develop).environmentObject(model))))
        UserDefaults.standard.set(Theme.light.rawValue, forKey: Theme.defaultsKey)
        Theme.light.apply()
        for (name, size, view) in shots {
            await capture(view, size: size, to: folder.appendingPathComponent(name + ".png"))
        }
        let frameHUD = UserDefaults.standard.bool(forKey: DevelopFrameHUD.preference)
        UserDefaults.standard.set(true, forKey: DevelopFrameHUD.preference)
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-frame-diagnostics-1280x800.png"))
        UserDefaults.standard.set(frameHUD, forKey: DevelopFrameHUD.preference)
        // Slider Compare adds a hint to the wide toolbar. Check it both with room and
        // with the editing panels open in the smallest supported window.
        model.develop.compareMode = .slider
        for width in [1000, 1728] {
            await capture(AnyView(ContentView().environmentObject(model)),
                          size: CGSize(width: width, height: 640),
                          to: folder.appendingPathComponent("develop-slider-compare-\(width)x640.png"))
        }
        if let after = model.develop.image {
            let waiting = SliderCompareView(before: nil, after: after, pixelSize: nil, zoom: ZoomState(),
                                            onReport: { _ in }, menu: { nil }, position: .constant(0.5))
            await capture(AnyView(waiting), size: CGSize(width: 640, height: 380),
                          to: folder.appendingPathComponent("develop-slider-compare-loading.png"))
        }
        model.develop.compareMode = .off
        // The crop tool, straightened a little.
        model.develop.isCropping = true
        var crop = model.develop.crop
        crop.angle = 4
        model.develop.setCrop(crop.fitted(imageAspect: model.develop.orientedAspect))
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-crop-1280x800.png"))
        model.develop.isCropping = false
        // The AI tool with a brush stroke painted.
        model.develop.isAIOpen = true
        model.ai.strokes = [BrushStroke(points: [CGPoint(x: 0.42, y: 0.5), CGPoint(x: 0.5, y: 0.56), CGPoint(x: 0.58, y: 0.52)],
                                        radius: 0.03)]
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-ai-1280x800.png"))
        model.develop.isAIOpen = false
        await snapshotClipping(model: model, into: folder)
        await snapshotSliderPreviews(model: model, into: folder)
        await snapshotColorGrading(model: model, into: folder)
        await snapshotColorTools(model: model, into: folder)
        await snapshotMatchLook(model: model, into: folder)
        await snapshotMasking(model: model, into: folder)
        await snapshotRemove(model: model, into: folder)
        await snapshotLensBlurMode(model: model, into: folder)
        await snapshotTransform(model: model, into: folder)
        await snapshotPresets(model: model, into: folder)
        // Each theme in Develop at the size in Rosh's screenshot, and the theme picker itself.
        for theme in Theme.allCases where theme != .system {
            UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
            theme.apply()
            await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                          to: folder.appendingPathComponent("theme-\(theme.rawValue).png"))
        }
        // Loupe (E): the info overlay on the photo and the right panel's histogram, File and Camera sections.
        model.openLoupe()
        try? await Task.sleep(for: .seconds(2))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("loupe-1280x800.png"))
        await snapshotNotes(model: model, into: folder)
        await snapshotHDR(model: model, into: folder)
        model.mode = .grid
        // Render and catalog an Edit In copy to show the stack without opening Preview.
        model.selection = Set(model.rows.map(\.id))
        model.editIn(ExternalEditor(name: "Preview", appURL: URL(fileURLWithPath: "/System/Applications/Preview.app")))
        for _ in 0..<40 where model.rows.count < 2 { try? await Task.sleep(for: .milliseconds(250)) }
        print("SNAPSHOT: after Edit In, rows \(model.rows.map { "\($0.filename) parent=\($0.stackParentId.map(String.init) ?? "-") kind=\($0.stackKind?.rawValue ?? "-") count=\($0.stackCount ?? 0)" })")
        if let problem = model.problems.first { print("SNAPSHOT: Edit In problem \(problem.name): \(problem.reason)") }
        try? await Task.sleep(for: .seconds(2))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("theme-neutralGray-grid.png"))
        await snapshotVirtualCopy(model: model, into: folder)
        await snapshotCulling(model: model, into: folder)
        await snapshotFilmstrip(model: model, into: folder)
        await snapshotRawPair(model: model, into: folder)
        await snapshotPrivate(model: model, into: folder)
        await snapshotMetadata(into: folder)
        await capture(AnyView(ImportSettings().frame(width: 560)), size: CGSize(width: 560, height: 420),
                      to: folder.appendingPathComponent("settings-import.png"))
        // The Import dialog's progress step, partway through a copy.
        var copying = ImportProgress()
        (copying.total, copying.processed) = (412, 137)
        (copying.totalBytes, copying.bytesDone) = (18_400_000_000, 6_100_000_000)
        copying.currentFile = URL(fileURLWithPath: "/Volumes/NIKON Z 6/DCIM/100NCZ_6/NZ6_9144.NEF")
        model.importProgress = LibraryModel.importStatus(copying, copying: true, speed: 180_000_000)
        await capture(AnyView(ImportProgressStep(copying: true) {}.environmentObject(model)),
                      size: CGSize(width: ImportSheet.size.width, height: ImportSheet.size.height - 92),
                      to: folder.appendingPathComponent("import-progress.png"))
        model.importProgress = nil
        await capture(AnyView(AppearanceSettings().frame(width: 560)), size: CGSize(width: 560, height: 470),
                      to: folder.appendingPathComponent("settings-appearance.png"))
        await capture(AnyView(EditInSettings().frame(width: 640)), size: CGSize(width: 640, height: 360),
                      to: folder.appendingPathComponent("settings-editin.png"))
        await capture(AnyView(AISettingsTab().frame(width: 640)), size: CGSize(width: 640, height: 600),
                      to: folder.appendingPathComponent("settings-ai.png"))
        await capture(AnyView(GeneralSettings().environmentObject(model).frame(width: 640)), size: CGSize(width: 640, height: 780),
                      to: folder.appendingPathComponent("settings-general.png"))
        await snapshotSettingsWindow(model: model, into: folder)
        await snapshotStorage(model: model, into: folder)
        await snapshotExport(model: model, into: folder)
        // The splash with each built-in image, and with none.
        for url in SplashController.builtInImages {
            let image = SplashImage.load(url)
            print("SNAPSHOT: splash \(url.lastPathComponent) \(String(describing: image?.layout))")
            let view = SplashContentView(image: image)
            view.setStatus("Ready · 1,234 photos · megham offline", progress: 1)
            capture(view, to: folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png"))
        }
        let empty = SplashContentView(image: nil)
        empty.setStatus("Checking drives and network volumes…", progress: 0.55)
        capture(empty, to: folder.appendingPathComponent("splash-empty.png"))
        UserDefaults.standard.removeObject(forKey: Theme.defaultsKey)
        Theme.system.apply()
        fflush(stdout)
        exit(0)
    }

    /// The sticky notes panel (AT-058) over Loupe, with a list, a checkbox and bold text, in the
    /// current theme and Graphite. The notes are taken off again so later snapshots don't change.
    private static func snapshotNotes(model: LibraryModel, into folder: URL) async {
        guard let id = model.focusedID else { return print("SNAPSHOT: no photo for notes") }
        let catalog = model.catalog
        let day = Date(timeIntervalSince1970: 1_794_000_000)
        let added = (try? catalog.addNote("Second pass: **keep** for the shop.\n- [ ] Crop tighter\n- [x] Fix the horizon",
                                          to: [id], at: day)) ?? []
        let cull = (try? catalog.addNote("Rejected: eyes closed in 2 of 3 faces", source: .cull, to: [id],
                                         at: day.addingTimeInterval(-3600))) ?? []
        let visible = NotesPanel.isVisible, theme = Theme.current
        NotesPanel.isVisible = true
        try? await Task.sleep(for: .milliseconds(500))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("loupe-notes-1280x800.png"))
        UserDefaults.standard.set(Theme.graphite.rawValue, forKey: Theme.defaultsKey)
        Theme.graphite.apply()
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("loupe-notes-graphite.png"))
        UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
        theme.apply()
        NotesPanel.isVisible = visible
        for note in added + cull { if let noteID = note.id { _ = try? catalog.deleteNote(noteID) } }
    }

    /// The whole Settings window (sidebar and pane) on a few panes, in Light and Graphite.
    /// HDR mode (Photo > HDR…): the sliders moved a little, then Slider compare in the smallest window.
    private static func snapshotHDR(model: LibraryModel, into folder: URL) async {
        model.openHDR()
        let hdr = model.hdr
        for _ in 0..<100 where hdr.after == nil { try? await Task.sleep(for: .milliseconds(100)) }
        if hdr.after == nil { print("SNAPSHOT: HDR has no rendered photo (\(hdr.error ?? "no error"))") }
        let exposure = hdr.binding(\.exposure), microcontrast = hdr.binding(\.microcontrast)
        exposure.wrappedValue += 0.3
        microcontrast.wrappedValue = 0.5
        try? await Task.sleep(for: .seconds(2))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("hdr-1280x800.png"))
        hdr.compareMode = .slider
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("hdr-slider-1000x584.png"))
        hdr.compareMode = .off
        hdr.discardChanges()
    }

    static func snapshotSettingsWindow(model: LibraryModel, into folder: URL) async {
        let savedTheme = UserDefaults.standard.object(forKey: Theme.defaultsKey)
        let savedPane = UserDefaults.standard.object(forKey: SettingsPane.defaultsKey)
        defer {
            if let savedTheme { UserDefaults.standard.set(savedTheme, forKey: Theme.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: Theme.defaultsKey) }
            Theme.current.apply()
            if let savedPane { UserDefaults.standard.set(savedPane, forKey: SettingsPane.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: SettingsPane.defaultsKey) }
        }
        let shots: [(Theme, SettingsPane)] = [(.light, .general), (.light, .appearance), (.light, .ai), (.light, .agents), (.light, .keyboard),
                                              (.graphite, .general), (.graphite, .editIn)]
        for (theme, pane) in shots {
            UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
            theme.apply()
            UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.defaultsKey)
            await capture(AnyView(SettingsView().environmentObject(model)), size: SettingsView.size,
                          to: folder.appendingPathComponent("settings-window-\(pane.rawValue)-\(theme.rawValue).png"))
        }
    }

    /// Can run without opening a catalog via ATELIER_METADATA_SNAPSHOTS.
    static func snapshotMetadata(into folder: URL) async {
        let savedTheme = UserDefaults.standard.object(forKey: Theme.defaultsKey)
        defer {
            if let savedTheme { UserDefaults.standard.set(savedTheme, forKey: Theme.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: Theme.defaultsKey) }
            Theme.current.apply()
        }
        for theme in [Theme.light, .graphite] {
            UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
            theme.apply()
            await capture(AnyView(MetadataSettings().frame(width: 560, height: 260)),
                          size: CGSize(width: 560, height: 260),
                          to: folder.appendingPathComponent("settings-metadata-\(theme.rawValue).png"))
        }
    }

    /// Uses a disposable damaged database, never the user's catalog.
    static func snapshotCatalogRecovery(into folder: URL) async {
        let savedTheme = UserDefaults.standard.object(forKey: Theme.defaultsKey)
        defer {
            if let savedTheme { UserDefaults.standard.set(savedTheme, forKey: Theme.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: Theme.defaultsKey) }
            Theme.current.apply()
        }
        let root = fixtures(in: folder).appendingPathComponent("recovery")
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Atelier Catalog.atelier")
        try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try? Data("Damaged catalog fixture".utf8).write(to: package.appendingPathComponent("catalog.sqlite"))
        let opening = CatalogOpening(packageURL: package)
        await opening.open()
        for theme in [Theme.light, .graphite] {
            UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
            theme.apply()
            await capture(AnyView(CatalogRecoveryView(opening: opening, retry: {}).frame(width: 1000, height: 640)),
                          size: CGSize(width: 1000, height: 640),
                          to: folder.appendingPathComponent("catalog-recovery-\(theme.rawValue).png"))
        }
    }

    /// Exposure pushed until the sky clips, with the clipping overlay (J) on: the histogram's
    /// highlight triangle lit and the clipped area red on the photo.
    private static func snapshotClipping(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        let exposure = develop.settings[.exposure]
        develop.set(.exposure, to: 2)
        develop.toggleClippingOverlay()
        try? await Task.sleep(for: .seconds(2))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-clipping-1280x800.png"))
        develop.toggleClippingOverlay()
        develop.set(.exposure, to: exposure)
        try? await Task.sleep(for: .seconds(1))
    }

    /// The Presets panel with groups open, the Amount slider and Recent, a B&W pack preset on the photo,
    /// and the Create Preset and Manage Presets dialogs.
    private static func snapshotPresets(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        UserDefaults.standard.set("pack:Film\npack:Black & White", forKey: "presets.toggledGroups")
        develop.clearRecentPresets()
        develop.createPreset(name: "Snapshot Look", group: "Weddings", parts: [.tone, .colorGrading])
        if let portrait = develop.presets.first(where: { $0.name == "Portrait 400" }) {
            develop.applyPreset(portrait)
            develop.setPresetAmount(60)
        }
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(DevelopSidebar(develop: develop).environmentObject(model)), size: CGSize(width: 280, height: 1100),
                      to: folder.appendingPathComponent("presets-panel-280x1100.png"))
        // Zoomed in: the Navigator outlines the part of the photo in view.
        model.zoomState.viewport.update(CGRect(x: 0.35, y: 0.25, width: 0.4, height: 0.45), from: develop)
        await capture(AnyView(DevelopSidebar(develop: develop).environmentObject(model)), size: CGSize(width: 280, height: 400),
                      to: folder.appendingPathComponent("navigator-zoomed-280x400.png"))
        model.zoomState.viewport.clear(from: develop)
        // Hovering a preset previews it in the Navigator only.
        if let noir = develop.presets.first(where: { $0.name == "Noir" }) {
            develop.previewPreset(noir)
            try? await Task.sleep(for: .seconds(2))
            print("SNAPSHOT: navigator preview \(develop.navigatorPreview.map { "\($0.size)" } ?? "none")")
            await capture(AnyView(DevelopSidebar(develop: develop).environmentObject(model)), size: CGSize(width: 280, height: 700),
                          to: folder.appendingPathComponent("presets-navigator-preview-280x700.png"))
            develop.previewPreset(nil)
        }
        if let darkSky = develop.presets.first(where: { $0.name == "Dark Sky" }) {
            develop.applyPreset(darkSky)
        }
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: presets \(develop.presets.count), monochrome \(develop.settings.monochrome)")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-bw-preset-1280x800.png"))
        await capture(AnyView(PresetSheet(develop: develop, mode: .create(group: nil))), size: CGSize(width: 500, height: 520),
                      to: folder.appendingPathComponent("presets-create-dialog.png"))
        await capture(AnyView(ManagePresetsSheet(develop: develop)), size: CGSize(width: 400, height: 400),
                      to: folder.appendingPathComponent("presets-manage-dialog.png"))
        if let created = develop.presets.first(where: { $0.name == "Snapshot Look" }) { develop.deletePreset(created) }
        UserDefaults.standard.removeObject(forKey: "presets.toggledGroups")
        develop.clearRecentPresets()
        develop.resetAll()
        develop.flushSave()
    }

    /// The Match Look dialog with a warm, teal-shadowed reference, then with Match Areas on.
    private static func snapshotMatchLook(model: LibraryModel, into folder: URL) async {
        let url = fixtures(in: folder).appendingPathComponent("atelier-reference.jpg")
        let width = 1200, height = 800
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            let colors = [CGColor(srgbRed: 0.05, green: 0.18, blue: 0.2, alpha: 1),
                          CGColor(srgbRed: 0.55, green: 0.45, blue: 0.35, alpha: 1),
                          CGColor(srgbRed: 1, green: 0.78, blue: 0.5, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            }
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.55, blue: 0.4, alpha: 1))
            context.fillEllipse(in: CGRect(x: 450, y: 250, width: 300, height: 300))
            if let image = context.makeImage(),
               let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        model.beginMatchLook()
        guard let match = model.matchLook else {
            print("SNAPSHOT: Match Look did not open: \(model.status ?? "-")")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        match.useFile(url)
        func waitForMatch(_ match: MatchLookModel) async {
            try? await Task.sleep(for: .milliseconds(500))
            for _ in 0..<60 where !match.canApply { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(1))
        }
        await waitForMatch(match)
        print("SNAPSHOT: match look \(match.match.flatMap { try? $0.matched.encoded() } ?? "none"), message \(match.message ?? "-")")
        await capture(AnyView(MatchLookSheet(match: match).environmentObject(model)), size: CGSize(width: 900, height: 660),
                      to: folder.appendingPathComponent("match-look.png"))
        await capture(AnyView(MatchDifferencesView(lines: match.differences)), size: CGSize(width: 300, height: 420),
                      to: folder.appendingPathComponent("match-look-differences.png"))
        match.areaMode = .boxes
        match.photoArea = CGRect(x: 0.1, y: 0.15, width: 0.35, height: 0.3)
        await waitForMatch(match)
        await capture(AnyView(MatchLookSheet(match: match).environmentObject(model)), size: CGSize(width: 900, height: 660),
                      to: folder.appendingPathComponent("match-look-areas.png"))
        match.areaMode = .subject
        match.skinMode = .protect
        await waitForMatch(match)
        print("SNAPSHOT: match look subject \(match.match.flatMap { try? $0.matched.encoded() } ?? "none"), message \(match.message ?? "-")")
        await capture(AnyView(MatchLookSheet(match: match).environmentObject(model)), size: CGSize(width: 900, height: 660),
                      to: folder.appendingPathComponent("match-look-subject.png"))
        match.useBuiltIn(.furyRoadScene)
        await waitForMatch(match)
        await capture(AnyView(MatchLookSheet(match: match).environmentObject(model)), size: CGSize(width: 900, height: 660),
                      to: folder.appendingPathComponent("match-look-built-in.png"))
        match.skinMode = .match
        await waitForMatch(match)
        await capture(AnyView(MatchLookSheet(match: match).environmentObject(model)), size: CGSize(width: 900, height: 660),
                      to: folder.appendingPathComponent("match-look-skin-missing.png"))
        model.matchLook = nil
        // The Help comparison uses a real portrait and the same skin-only fit.
        guard let portrait = HelpWindow.folder?.appendingPathComponent("images/match-skin-before.jpg") else { return }
        let skin = MatchLookModel(library: model, assetID: match.assetID, targets: [match.assetID],
                                  url: portrait, settings: .neutral)
        skin.options = .init(whiteBalance: false, tone: false, color: false)
        skin.skinMode = .match
        skin.useBuiltIn(.matrixPortrait)
        await waitForMatch(skin)
        guard skin.match.map({ !$0.skinMasks.isEmpty }) == true else {
            print("SNAPSHOT: Match Skin Tone did not create a skin mask: \(skin.message ?? "-")")
            return
        }
        await capture(AnyView(MatchLookSheet(match: skin).environmentObject(model)), size: CGSize(width: 900, height: 660),
                      to: folder.appendingPathComponent("match-look-skin.png"))
        await capture(AnyView(MatchDifferencesView(lines: skin.differences)), size: CGSize(width: 300, height: 240),
                      to: folder.appendingPathComponent("match-look-skin-differences.png"))
    }

    /// Masking: a darker sky from a linear gradient, a brighter radial spot, and the overlay.
    /// Each Option-drag view, as it shows while the slider is dragged with Option held.
    private static func snapshotSliderPreviews(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        develop.set(.sharpening, to: 70)
        develop.set(.sharpenMasking, to: 40)
        develop.set(.whites, to: 60)
        develop.set(.blacks, to: -60)
        let previews: [(String, SliderPreview)] = [("sharpen-amount", .sharpenAmount), ("sharpen-edges", .sharpenEdges),
                                                   ("sharpen-mask", .sharpenMask), ("clipping-highlights", .highlightClipping),
                                                   ("clipping-shadows", .shadowClipping),
                                                   ("grade-hue", .fullSaturation(.midtones)),
                                                   ("grade-balance", .gradeRegions), ("grade-solo-shadows", .gradeSolo(.shadows))]
        for (name, preview) in previews {
            develop.sliderPreview = preview
            try? await Task.sleep(for: .seconds(1))
            await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                          to: folder.appendingPathComponent("develop-option-\(name)-1280x800.png"))
        }
        develop.sliderPreview = nil
        for parameter in [DevelopSettings.Parameter.sharpening, .sharpenMasking, .whites, .blacks] { develop.reset(parameter) }
    }

    /// Color Grading: the 3-Way view and each single wheel, with the photo's colors on the
    /// wheels and the tonal range graph, the panel switched off, and the color picker's hint.
    private static func snapshotColorGrading(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        develop.set(.gradeMidtonesLum, to: 10)
        develop.set(.gradeBalance, to: -20)
        try? await Task.sleep(for: .seconds(1))
        for view in ["3-Way"] + DevelopSettings.GradeRegion.allCases.map(\.rawValue) {
            UserDefaults.standard.set(view, forKey: "develop.gradeView")
            await capture(AnyView(ColorGradingPanel(develop: develop).padding(12).frame(width: 320)
                                    .background(Color(nsColor: .windowBackgroundColor))),
                          size: CGSize(width: 320, height: view == "3-Way" ? 590 : 550),
                          to: folder.appendingPathComponent("color-grading-\(view.lowercased())-320.png"))
        }
        UserDefaults.standard.set("3-Way", forKey: "develop.gradeView")
        // A built-in Color Grading preset: its name shows in the panel's Preset menu.
        let gradeBefore = develop.settings
        if let teal = SectionPresetKind.colorGrading.builtIn.first(where: { $0.name == "Teal & Orange" }) {
            develop.applySectionPreset(teal, kind: .colorGrading)
            try? await Task.sleep(for: .seconds(1))
            print("SNAPSHOT: color grading preset \(develop.sectionPresetTitle(.colorGrading))")
            await capture(AnyView(ColorGradingPanel(develop: develop).padding(12).frame(width: 320)
                                    .background(Color(nsColor: .windowBackgroundColor))),
                          size: CGSize(width: 320, height: 590),
                          to: folder.appendingPathComponent("color-grading-preset-320.png"))
            develop.apply(gradeBefore, onto: nil, step: "Snapshot")
        }
        develop.setPanelOn(.colorGrading, false)
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-grading-off-1280x800.png"))
        develop.setPanelOn(.colorGrading, true)
        develop.isPickingGradeColor = true
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-grading-picker-1280x800.png"))
        develop.isPickingWhiteBalance = true
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-wb-picker-1280x800.png"))
        develop.picker = nil
        develop.setPanelOn(.detail, false)
        develop.setPanelOn(.effects, false)
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(DevelopPanel(develop: develop).environmentObject(model)), size: CGSize(width: 320, height: 2600),
                      to: folder.appendingPathComponent("panel-switches-off-320x2600.png"))
        develop.setPanelOn(.detail, true)
        develop.setPanelOn(.effects, true)
        develop.reset(.gradeMidtonesLum)
        develop.reset(.gradeBalance)
    }

    /// Tone Curve (Parametric and Point), HSL / Color (Mixer and Point Color) and Effects, each
    /// panel alone at the panel's width, plus the Targeted Adjustment Tool's hint on the photo.
    private static func snapshotColorTools(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        func panel(_ view: some View, _ name: String, height: CGFloat) async {
            await capture(AnyView(view.padding(12).frame(width: 320).background(Color(nsColor: .windowBackgroundColor))),
                          size: CGSize(width: 320, height: height), to: folder.appendingPathComponent("\(name)-320.png"))
        }
        develop.set(.curveShadows, to: 30)
        develop.set(.curveHighlights, to: -20)
        develop.set(.curveMidtoneSplit, to: 45)
        UserDefaults.standard.set("parametric", forKey: DevelopController.curveModeKey)
        try? await Task.sleep(for: .seconds(1))
        await panel(ToneCurvePanel(develop: develop), "tone-curve-parametric", height: 550)
        develop.setPoints([.init(x: 0, y: 0.05), .init(x: 0.3, y: 0.24), .init(x: 0.7, y: 0.78), .init(x: 1, y: 1)], for: .rgb)
        develop.set(.curveRefineSaturation, to: 60)
        UserDefaults.standard.set("point", forKey: DevelopController.curveModeKey)
        UserDefaults.standard.set("rgb", forKey: DevelopController.curveChannelKey)
        try? await Task.sleep(for: .seconds(1))
        await panel(ToneCurvePanel(develop: develop), "tone-curve-point", height: 590)
        // A built-in Tone Curve preset: its name shows in the panel's Preset menu.
        let curveBefore = develop.settings
        if let matte = SectionPresetKind.toneCurve.builtIn.first(where: { $0.name == "Matte" }) {
            develop.applySectionPreset(matte, kind: .toneCurve)
            try? await Task.sleep(for: .seconds(1))
            print("SNAPSHOT: tone curve preset \(develop.sectionPresetTitle(.toneCurve))")
            await panel(ToneCurvePanel(develop: develop), "tone-curve-preset", height: 590)
            develop.apply(curveBefore, onto: nil, step: "Snapshot")
        }

        develop.set(.hsl(.saturation, .blue), to: 30)
        develop.set(.hsl(.luminance, .blue), to: -25)
        UserDefaults.standard.set("mixer", forKey: "develop.colorMixerView")
        UserDefaults.standard.set("Saturation", forKey: "develop.hslChannel")
        await panel(HSLPanel(develop: develop), "hsl-mixer", height: 340)
        develop.setValues([.pointColor(0, .hue): 55, .pointColor(0, .chroma): 8, .pointColor(0, .lightness): 72,
                           .pointColor(0, .satShift): -20, .pointColor(0, .uniformity): 40], step: "Point Color 1")
        develop.pointColorSwatch = 0
        UserDefaults.standard.set("point", forKey: "develop.colorMixerView")
        try? await Task.sleep(for: .seconds(1))
        await panel(HSLPanel(develop: develop), "hsl-point-color", height: 360)
        UserDefaults.standard.set("mixer", forKey: "develop.colorMixerView")

        develop.set(.vignetteRoundness, to: -30)
        develop.set(.glowAmount, to: 40)
        develop.set(.glowStyle, to: Double(DevelopSettings.GlowStyle.halation.rawValue))
        develop.set(.grainType, to: Double(DevelopSettings.GrainType.cubic.rawValue))
        try? await Task.sleep(for: .seconds(1))
        await panel(EffectsPanel(develop: develop), "effects", height: 450)
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-effects-1280x800.png"))

        develop.picker = .targetColor
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-targeted-1280x800.png"))
        develop.picker = nil
        for parameter in [DevelopSettings.Parameter.curveShadows, .curveHighlights, .curveMidtoneSplit, .curveRefineSaturation,
                          .vignetteRoundness, .glowAmount, .glowStyle, .grainType] {
            develop.reset(parameter)
        }
        develop.setPoints([], for: .rgb)
        develop.reset(.hsl)
    }

    private static func snapshotMasking(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        develop.isMasking = true
        develop.createMask(.linear)
        develop.finishDrawing(.linear(.init(start: .init(x: 0.5, y: 0.05), end: .init(x: 0.5, y: 0.45))))
        develop.setMaskValue(.exposure, to: -1.2)
        develop.setMaskValue(.dehaze, to: 25)
        develop.createMask(.radial)
        develop.finishDrawing(.radial(.init(center: .init(x: 0.62, y: 0.6), radiusX: 0.18, radiusY: 0.12, angle: 20)))
        develop.setMaskValue(.exposure, to: 0.8)
        develop.setMaskValue(.temperature, to: 30)
        develop.addComponent(.luminance, mode: .intersect)
        if let mask = develop.selectedMask, let radial = mask.components.first {
            develop.select(mask: mask.id, component: radial.id)
        }
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: masks \(develop.masks.map { "\($0.name) parts=\($0.components.map(\.kind.rawValue))" })")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-masking-1280x800.png"))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("develop-masking-1000x584.png"))
        await capture(AnyView(DevelopPanel(develop: develop).environmentObject(model)), size: CGSize(width: 320, height: 1500),
                      to: folder.appendingPathComponent("panel-masking-320x1500.png"))
        develop.showMaskOverlay = true
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-masking-overlay-1280x800.png"))
        develop.showMaskOverlay = false
        // A brush part being painted into, with the brush settings showing.
        develop.createMask(.brush)
        develop.finishDrawing(.brush([.init(points: [.init(x: 0.2, y: 0.7), .init(x: 0.3, y: 0.75), .init(x: 0.4, y: 0.72)],
                                            size: 0.08)]))
        develop.setMaskValue(.saturation, to: -60)
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-masking-brush-1280x800.png"))
        // Zoomed to 100% while masking, with the brush part's pin in view.
        model.zoom = .percent(100)
        try? await Task.sleep(for: .seconds(2))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-masking-zoom-1280x800.png"))
        model.zoom = .fit
        // A Color Range part with two picks (a click and a dragged box): markers on the photo,
        // swatches and Refine in the panel.
        develop.createMask(.color)
        develop.finishDrawing(.color(.init(samples: [
            .init(box: .init(x: 0.3, y: 0.3, width: 0, height: 0), lab: SIMD3(0.62, 0.08, 0.06)),
            .init(box: .init(x: 0.55, y: 0.2, width: 0.12, height: 0.1), lab: SIMD3(0.7, -0.02, -0.08), spread: 0.02),
        ])))
        develop.setMaskValue(.saturation, to: 40)
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-masking-color-1280x800.png"))
        // Select Object with a box; the sample photo has no subject, so the panel says so.
        develop.createMask(.object)
        develop.finishDrawing(.subject(.init(box: .init(x: 0.45, y: 0.4, width: 0.3, height: 0.35))))
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: select object message \(develop.maskMessage ?? "-")")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-masking-object-1280x800.png"))
        develop.deleteAllMasks()
        develop.isMasking = false
        develop.flushSave()
    }

    /// The Remove tool (AT-066): a Heal click, a Clone stroke selected with its source, and
    /// Visualize Spots.
    private static func snapshotRemove(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        develop.isRemoving = true
        develop.spotMode = .heal
        develop.spotSize = 0.04
        develop.addSpot(points: [.init(x: 0.3, y: 0.35)])
        develop.spotMode = .clone
        develop.spotSize = 0.02
        develop.addSpot(points: [.init(x: 0.55, y: 0.6), .init(x: 0.62, y: 0.62), .init(x: 0.7, y: 0.6)])
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: spots \(develop.spots.map { "\($0.mode.rawValue) points=\($0.points.count) offset=\($0.offset)" })")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-remove-1280x800.png"))
        await capture(AnyView(DevelopPanel(develop: develop).environmentObject(model)), size: CGSize(width: 320, height: 900),
                      to: folder.appendingPathComponent("panel-remove-320x900.png"))
        develop.visualizesSpots = true
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-remove-visualize-1280x800.png"))
        develop.visualizesSpots = false
        develop.deleteAllSpots()
        develop.isRemoving = false
        develop.spotMode = .heal
        develop.spotSize = DevelopSettings.Spot.defaultSize
        develop.flushSave()
    }

    /// The Lens Blur mode (AT-074): its own screen (no filmstrip, no left column, no histogram),
    /// Refine with Show Overlay on a Focus area, then Cancel, which must bring Develop back
    /// whole (left column, presets) with the mode's changes undone. Without the depth model
    /// (CI) the panel shows its download offer.
    private static func snapshotLensBlurMode(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        let areasBefore = develop.settings.lensBlurAreas.count
        let amountBefore = develop.settings[.lensBlurAmount]
        let started = Date()
        develop.isLensBlurring = true
        try? await Task.sleep(for: .seconds(1))
        print("SNAPSHOT: lens blur mode \(develop.isLensBlurring) open \(model.isLensBlurOpen) state \(develop.lensBlurPhotoState)")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-lens-blur-1280x800.png"))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("develop-lens-blur-1000x584.png"))
        await capture(AnyView(DevelopPanel(develop: develop).environmentObject(model)), size: CGSize(width: 320, height: 900),
                      to: folder.appendingPathComponent("panel-lens-blur-320x900.png"))
        // An edit made in the mode, and a Focus area shown with the overlay in Refine.
        develop.set(.lensBlurAmount, to: 80)
        develop.startLensBlurRefine()
        var focus = DevelopSettings.Mask(name: "Focus",
                                         components: [.init(.radial(.init(center: .init(x: 0.5, y: 0.5),
                                                                           radiusX: 0.2, radiusY: 0.25)))])
        focus.lensBlurRole = .focus
        develop.editedMasks = [focus]
        develop.selectedMaskID = nil
        let overlay = develop.showMaskOverlay
        develop.showMaskOverlay = true
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-lens-blur-refine-overlay-1280x800.png"))
        develop.showMaskOverlay = overlay
        develop.finishLensBlurRefine()
        print("SNAPSHOT: lens blur work line \(develop.lensBlurWork ?? "none") after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        // Cancel: Develop with its left column and filmstrip, the edits undone.
        model.closeLensBlur()
        try? await Task.sleep(for: .seconds(1))
        print("SNAPSHOT: after Cancel mode \(develop.isLensBlurring) open \(model.isLensBlurOpen) areas \(develop.settings.lensBlurAreas.count) (was \(areasBefore)) amount \(develop.settings[.lensBlurAmount]) (was \(amountBefore))")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-after-lens-blur-cancel-1280x800.png"))
        develop.flushSave()
    }

    /// Guided Upright with two converging guides, Constrain Crop on, and the Lens Corrections and
    /// Transform panels.
    private static func snapshotTransform(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        let expanded = UserDefaults.standard.string(forKey: "develop.expandedPanels")
        UserDefaults.standard.set("histogram,basic,lensCorrections,transform", forKey: "develop.expandedPanels")
        develop.setUpright(.guided)
        develop.setGuides([
            .init(start: .init(x: 0.3, y: 0.85), end: .init(x: 0.33, y: 0.2)),
            .init(start: .init(x: 0.72, y: 0.85), end: .init(x: 0.69, y: 0.2)),
        ])
        develop.setConstrainCrop(true)
        develop.set(.lensDistortion, to: 15)
        develop.setRemoveChromaticAberration(true)
        develop.set(.lensDefringePurpleAmount, to: 6)
        develop.setHueRange(.green, low: 35, high: 65)
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: upright \(String(describing: develop.settings.upright))")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-guided-1280x800.png"))
        develop.isGuiding = false
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-transform-1280x800.png"))
        await capture(AnyView(DevelopPanel(develop: develop).environmentObject(model)), size: CGSize(width: 320, height: 1900),
                      to: folder.appendingPathComponent("panel-transform-320x1900.png"))
        // Defringe: the Fringe Color Selector out, and the Purple Hue Option-drag view.
        develop.isPickingFringe = true
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-fringe-picker-1280x800.png"))
        develop.isPickingFringe = false
        develop.sliderPreview = .defringeHue(.purple)
        try? await Task.sleep(for: .seconds(2))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-defringe-hue-1280x800.png"))
        develop.sliderPreview = nil
        develop.reset(.transform)
        develop.reset(.lensCorrections)
        develop.flushSave()
        UserDefaults.standard.set(expanded, forKey: "develop.expandedPanels")
    }

    /// A virtual copy of the sample photo turned black and white, next to the colour original.
    private static func snapshotVirtualCopy(model: LibraryModel, into folder: URL) async {
        guard let original = model.rows.first(where: { $0.stackKind == nil })?.id else { return }
        model.selection = [original]
        model.focusedID = original
        model.createVirtualCopies()
        for _ in 0..<20 where !model.rows.contains(where: { $0.stackKind == .virtualCopy }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let copy = model.rows.first(where: { $0.stackKind == .virtualCopy })?.id else {
            print("SNAPSHOT: virtual copy missing")
            return
        }
        model.focusedID = copy
        model.mode = .develop
        // Let Develop load the photo, so saving renders the new thumbnail.
        try? await Task.sleep(for: .seconds(2))
        model.develop.set(.saturation, to: -100)
        model.develop.flushSave()
        model.mode = .grid
        try? await Task.sleep(for: .seconds(3))
        print("SNAPSHOT: after virtual copy, rows \(model.rows.map { "\($0.filename) kind=\($0.stackKind?.rawValue ?? "-") name=\($0.stackName ?? "-")" }), original saturation \((try? model.catalog.developSettings(for: original))?.saturation ?? .nan), copy \((try? model.catalog.developSettings(for: copy))?.saturation ?? .nan)")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("virtual-copy-grid.png"))
        // The Filmstrip collapsed to its arrow tab.
        UserDefaults.standard.set(false, forKey: Filmstrip.visibleKey)
        try? await Task.sleep(for: .milliseconds(300))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("filmstrip-collapsed.png"))
        UserDefaults.standard.set(true, forKey: Filmstrip.visibleKey)
        // The Filmstrip's right-click menu with two photos selected, from Develop.
        if model.rows.count > 1 {
            model.mode = .develop
            model.selection = [model.rows[0].id]
            let menu = model.filmstripMenu(for: model.rows[1].id)
            model.selection.insert(model.rows[0].id)
            model.menuTargets = model.rows.prefix(2).map(\.id)
            print("SNAPSHOT: filmstrip menu targets \(model.targetIDs.count): \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.submenu.map { " (\($0.items.count))" } ?? "") })")
            model.menuTargets = nil
            model.mode = .grid
        }
    }

    /// The Filmstrip's header and thumbnail badges (AT-018): flags, stars, labels, an edit and a
    /// multiple selection, in Develop for two themes and at the smallest Filmstrip height, and
    /// the grid at its largest thumbnail size.
    private static func snapshotFilmstrip(model: LibraryModel, into folder: URL) async {
        model.sidebarSelection = .all
        for _ in 0..<20 where model.rows.count < 4 { try? await Task.sleep(for: .milliseconds(250)) }
        let ids = model.rows.map(\.id)
        guard ids.count >= 4 else {
            print("SNAPSHOT: filmstrip needs 4 photos, has \(ids.count)")
            return
        }
        try? model.catalog.setFlag(.picked, for: [ids[0], ids[2]])
        try? model.catalog.setFlag(.rejected, for: [ids[3]])
        try? model.catalog.setRating(4, for: [ids[0]])
        try? model.catalog.setRating(5, for: [ids[1]])
        try? model.catalog.toggleColorLabel(.red, for: [ids[0]])
        try? model.catalog.toggleColorLabel(.green, for: [ids[1]])
        model.filter.minRating = 0
        model.selection = [ids[0], ids[1], ids[2]]
        model.focusedID = ids[1]
        model.mode = .develop
        model.develop.set(.exposure, to: 0.4)
        model.develop.flushSave()
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: filmstrip badges \(model.rows.prefix(6).map { "\($0.filename) edits=\($0.hasEdits) crop=\($0.isCropped) masks=\($0.hasMasks) offline=\($0.isOffline)" })")
        print("SNAPSHOT: source menu \(model.filmstripSourceMenu().items.map { $0.isSeparatorItem ? "—" : $0.title })")
        print("SNAPSHOT: filter menu \(model.filmstripFilterMenu().items.count) items, sort menu \(model.filmstripSortMenu().items.map(\.title))")
        let size = CGSize(width: 1280, height: 800)
        for theme in [Theme.graphite, .light] {
            UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
            theme.apply()
            for height in [Filmstrip.minHeight, 150.0] {
                UserDefaults.standard.set(height, forKey: Filmstrip.heightKey)
                try? await Task.sleep(for: .milliseconds(500))
                await capture(AnyView(ContentView().environmentObject(model)), size: size,
                              to: folder.appendingPathComponent("filmstrip-\(theme.rawValue)-\(Int(height)).png"))
            }
        }
        // Filtered to picks and sorted by rating, newest first: the header shows both.
        model.filter.flag = .picked
        model.filter.sort = .rating
        model.filter.ascending = false
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: size,
                      to: folder.appendingPathComponent("filmstrip-filtered.png"))
        model.filter = model.filter.cleared
        model.filter.sort = .captureTime
        model.filter.ascending = true
        // The grid at its largest thumbnails.
        model.mode = .grid
        UserDefaults.standard.set(GridThumbnails.sizeRange.upperBound, forKey: GridThumbnails.sizeKey)
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: size,
                      to: folder.appendingPathComponent("grid-large-thumbnails.png"))
        UserDefaults.standard.removeObject(forKey: GridThumbnails.sizeKey)
        UserDefaults.standard.set(Filmstrip.defaultHeight, forKey: Filmstrip.heightKey)
    }

    /// Culling before an import: three takes of one scene (one soft), two of another, and a
    /// single shot. Captures the Cull view, then imports and prints how the photos landed.
    private static func snapshotCulling(model: LibraryModel, into folder: URL) async {
        let dir = fixtures(in: folder).appendingPathComponent("culling")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shots: [(String, Int, Int, Bool)] = [("Beach-1", 0, 0, false), ("Beach-2", 0, 1, true), ("Beach-3", 0, 2, false),
                                                 ("Market-1", 1, 20, false), ("Market-2", 1, 21, false), ("Portrait", 2, 300, false)]
        var files: [URL] = []
        for (name, scene, second, soft) in shots {
            let url = dir.appendingPathComponent(name + ".jpg")
            writeScene(scene, shift: second % 3, soft: soft, second: second, to: url)
            files.append(url)
        }
        // The Import dialog's first step on these photos.
        model.pendingImportSources = [dir]
        await capture(AnyView(ImportSheet(model: model).environmentObject(model)), size: ImportSheet.size,
                      to: folder.appendingPathComponent("import-choose.png"))
        let importPresetKey = "import.developPreset"
        let savedPreset = UserDefaults.standard.string(forKey: importPresetKey)
        UserDefaults.standard.set("6E2B6B5A-0004-4C5E-9A7E-0A7E11E50004", forKey: importPresetKey)
        await capture(AnyView(ImportSheet(model: model).environmentObject(model)), size: ImportSheet.size,
                      to: folder.appendingPathComponent("import-retired-preset.png"))
        UserDefaults.standard.set(savedPreset, forKey: importPresetKey)
        // Apply During Import with a Tone Curve and a Color Grading preset after the Develop one (AT-057).
        let sectionKeys = ["import.toneCurvePreset", "import.colorGradingPreset"]
        let savedSections = sectionKeys.map { UserDefaults.standard.string(forKey: $0) }
        let matte = SectionPresetKind.toneCurve.builtIn.first { $0.name == "Matte" }
        let teal = SectionPresetKind.colorGrading.builtIn.first { $0.name == "Teal & Orange" }
        UserDefaults.standard.set(matte?.id.uuidString ?? "", forKey: sectionKeys[0])
        UserDefaults.standard.set(teal?.id.uuidString ?? "", forKey: sectionKeys[1])
        await capture(AnyView(ImportSheet(model: model).environmentObject(model)), size: ImportSheet.size,
                      to: folder.appendingPathComponent("import-section-presets.png"))
        for (key, value) in zip(sectionKeys, savedSections) { UserDefaults.standard.set(value, forKey: key) }
        model.pendingImportSources = []
        let cull = CullModel(source: .importing(sources: files, options: ImportOptions(target: .newGroup(name: "Cull Test"))),
                             title: "Cull Before Importing \u{201C}Cull Test\u{201D}", model: model)
        for _ in 0..<60 where cull.isAnalyzing { try? await Task.sleep(for: .milliseconds(250)) }
        let names = cull.photos.map(\.name)
        for a in cull.photos.indices {
            let row = cull.photos.indices.map { b -> String in
                guard let x = cull.photos[a].signals, let y = cull.photos[b].signals,
                      let d = Culling.distance(x, y) else { return "  -  " }
                return String(format: "%.2f", d)
            }
            print("SNAPSHOT: distance \(names[a]) \(row.joined(separator: " "))")
        }
        print("SNAPSHOT: sharpness \(cull.photos.map { "\($0.name)=\(Int($0.signals?.sharpness ?? 0))" })")
        for index in cull.photos.indices.dropLast() {
            guard let a = cull.photos[index].signals, let b = cull.photos[index + 1].signals else { continue }
            let c = Culling.compare(a, b)
            print("SNAPSHOT: \(names[index]) → \(names[index + 1]) frameChange=\(c.frameChange.map { String(format: "%.3f", $0) } ?? "-") aligned=\(c.aligned.map { String(format: "%.3f", $0) } ?? "-") feature=\(c.featureDistance.map { String(format: "%.3f", $0) } ?? "-") link=\(cull.link(index, index + 1))")
        }
        print("SNAPSHOT: cull mode \(cull.mode.rawValue) kinds \(cull.multiGroups.map { cull.isSameFrame($0) ? "same frame" : "similar" })")
        print("SNAPSHOT: cull groups \(cull.groups.map { $0.map { cull.photos[$0].name } }) kept \(cull.kept.map { cull.photos[$0].name }.sorted())")
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(CullView(cull: cull)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("cull-1280x800.png"))
        model.cullSession = cull
        cull.finish()
        for _ in 0..<40 where model.importProgress != nil { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .seconds(1))
        let all = (try? model.catalog.assetRows(filter: LibraryFilter())) ?? []
        print("SNAPSHOT: after cull import \(all.filter { $0.filename.hasSuffix(".jpg") && !$0.filename.hasPrefix("atelier") }.map { "\($0.filename) flag=\($0.flag) group=\($0.cullGroupSize ?? 0)" })")
        print("SNAPSHOT: status \(model.status ?? "-")")
        if let beach = all.first(where: { $0.filename == "Beach-2.jpg" }) {
            model.focusedID = beach.id
            model.showCullGroup()
            if let review = model.cullSession {
                for _ in 0..<40 where review.isAnalyzing { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .seconds(1))
                await capture(AnyView(CullView(cull: review)), size: CGSize(width: 1280, height: 800),
                              to: folder.appendingPathComponent("cull-group-review.png"))
                review.cancel()
            }
        }
    }

    /// The RAW+JPEG Test import made private: shown (lock after its name, Hide Private in the
    /// sidebar header), then View > Show Only Private Photos, then hidden (gone from Imports, All Photographs counts two photos fewer).
    private static func snapshotPrivate(model: LibraryModel, into folder: URL) async {
        guard let entry = model.sidebar.imports.first(where: { $0.name == "RAW+JPEG Test" }) else {
            print("SNAPSHOT: private import entry missing")
            return
        }
        model.mode = .grid
        model.filter.privacy = .shown
        model.setPrivate(true, importGroup: entry.id)
        model.sidebarSelection = .importGroup(entry.id)
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: private shown imports \(model.sidebar.imports.map { "\($0.name) private=\($0.isPrivate)" }) total \(model.sidebar.totalCount)")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("private-shown.png"))
        model.privatePhotos.choose(.only)
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: private only imports \(model.sidebar.imports.map(\.name)) total \(model.sidebar.totalCount) rows \(model.rows.map(\.filename))")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("private-only.png"))
        model.privatePhotos.hide()
        try? await Task.sleep(for: .seconds(2))
        print("SNAPSHOT: private hidden imports \(model.sidebar.imports.map(\.name)) total \(model.sidebar.totalCount) scope \(String(describing: model.sidebarSelection)) rows \(model.rows.map(\.filename))")
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                      to: folder.appendingPathComponent("private-hidden.png"))
        model.filter.privacy = .shown
        model.setPrivate(false, importGroup: entry.id)
        model.filter.privacy = .hidden
        try? await Task.sleep(for: .seconds(1))
    }

    /// A RAW+JPEG pair (the "RAW" is a JPEG renamed; the catalog goes by name) next to a lone
    /// JPEG: the grid shows two photos, the RAW marked RAW+JPG.
    private static func snapshotRawPair(model: LibraryModel, into folder: URL) async {
        let dir = fixtures(in: folder).appendingPathComponent("raw-pair")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeScene(0, shift: 0, soft: false, second: 400, to: dir.appendingPathComponent("DSC_0101.NEF"))
        writeScene(0, shift: 0, soft: false, second: 400, to: dir.appendingPathComponent("DSC_0101.JPG"))
        writeScene(1, shift: 0, soft: false, second: 410, to: dir.appendingPathComponent("DSC_0102.JPG"))
        model.runImport(sources: [dir], options: ImportOptions(target: .newGroup(name: "RAW+JPEG Test")))
        for _ in 0..<40 where model.importProgress != nil { try? await Task.sleep(for: .milliseconds(250)) }
        if let entry = model.sidebar.imports.first(where: { $0.name == "RAW+JPEG Test" }) {
            model.sidebarSelection = .importGroup(entry.id)
            var waited = 0
            while waited < 40, !model.rows.contains(where: { $0.filename == "DSC_0101.NEF" }) {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 1
            }
            print("SNAPSHOT: pair rows arrived after \(waited * 250) ms, selection \(String(describing: model.sidebarSelection)), status \(model.status ?? "-")")
            try? await Task.sleep(for: .seconds(1))
            do {
                let direct = try model.catalog.assetRows(filter: model.filter)
                print("SNAPSHOT: pair direct rows \(direct.map { "\($0.filename) paired=\($0.pairedFormats ?? "-")" }) filter \(model.filter)")
            } catch {
                print("SNAPSHOT: pair rows error \(error)")
            }
            print("SNAPSHOT: pair status \(model.status ?? "-")")
            print("SNAPSHOT: pair entry count \(entry.photoCount), rows \(model.rows.map { "\($0.filename) paired=\($0.pairedFormats ?? "-")" })")
            await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                          to: folder.appendingPathComponent("raw-pair-grid.png"))
            await snapshotRemovePhotos(model: model, into: folder)
            model.sidebarSelection = .all
        } else {
            print("SNAPSHOT: pair import entry missing")
        }
    }

    /// The Remove Photo dialog for the RAW+JPEG pair (a checkbox per kind of file) and for both
    /// photos, then Delete from Disk on the lone JPEG.
    private static func snapshotRemovePhotos(model: LibraryModel, into folder: URL) async {
        guard let raw = model.rows.first(where: { $0.filename == "DSC_0101.NEF" })?.id,
              let single = model.rows.first(where: { $0.filename == "DSC_0102.JPG" })?.id else {
            print("SNAPSHOT: remove photos skipped, rows \(model.rows.map(\.filename))")
            return
        }
        model.mode = .grid
        model.selection = [raw]
        model.focusedID = raw
        model.beginRemovePhotos()
        if let removal = model.removal {
            print("SNAPSHOT: remove plan \(removal.plan.files.map(\.filename)) types \(removal.plan.fileTypes.map(\.label))")
            await capture(AnyView(RemovePhotosSheet(removal: removal).environmentObject(model)), size: CGSize(width: 480, height: 250),
                          to: folder.appendingPathComponent("remove-photo-pair.png"))
        }
        model.selection = [raw, single]
        model.beginRemovePhotos()
        if let removal = model.removal {
            await capture(AnyView(RemovePhotosSheet(removal: removal).environmentObject(model)), size: CGSize(width: 480, height: 270),
                          to: folder.appendingPathComponent("remove-photos-two.png"))
        }
        model.removal = nil
        let url = try? model.catalog.fileURL(for: single)
        model.selection = [single]
        model.focusedID = single
        model.beginRemovePhotos()
        if let removal = model.removal {
            model.removePhotos(removal, types: Set(removal.plan.fileTypes), fromDisk: true)
        }
        try? await Task.sleep(for: .seconds(1))
        print("SNAPSHOT: after Delete from Disk, status \(model.status ?? "-"), file still there \(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false), rows \(model.rows.map(\.filename)), focused \(model.focusedID.map(String.init) ?? "-")")
    }

    /// The Export dialog with the Website preset selected, then with a text watermark added (no
    /// preset matches, so none is selected). The watermark section is below the fold.
    private static func snapshotExport(model: LibraryModel, into folder: URL) async {
        model.mode = .grid
        model.selection = Set(model.rows.map(\.id))
        model.beginExport()
        model.showingExportSheet = false
        var settings = ExportSettings(destination: folder)
        ExportPreset.website.apply(to: &settings)
        var watermark = ExportWatermark(text: "© 2026 Rosh Davis")
        watermark.size = 0.3
        ExportSheet.saveLast(settings, watermark: watermark)
        await capture(AnyView(ExportSheet().environmentObject(model)), size: ExportSheet.size,
                      to: folder.appendingPathComponent("export-website.png"))
        settings.watermark = watermark
        ExportSheet.saveLast(settings, watermark: watermark)
        await capture(AnyView(ExportSheet().environmentObject(model)), size: ExportSheet.size,
                      to: folder.appendingPathComponent("export-watermark.png"))
        UserDefaults.standard.removeObject(forKey: "export.lastSettings")
        UserDefaults.standard.removeObject(forKey: "export.lastWatermark")
    }

    private static func writeScene(_ scene: Int, shift: Int, soft: Bool, second: Int, to url: URL) {
        let width = 1200, height = 800
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        let palettes: [[CGColor]] = [
            [CGColor(srgbRed: 0.2, green: 0.45, blue: 0.75, alpha: 1), CGColor(srgbRed: 0.95, green: 0.85, blue: 0.6, alpha: 1)],
            [CGColor(srgbRed: 0.55, green: 0.15, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.95, green: 0.6, blue: 0.2, alpha: 1)],
            [CGColor(srgbRed: 0.1, green: 0.3, blue: 0.15, alpha: 1), CGColor(srgbRed: 0.7, green: 0.85, blue: 0.6, alpha: 1)],
        ]
        if let gradient = CGGradient(colorsSpace: space, colors: palettes[scene] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        // Detail to judge sharpness by: stripes for the beach, blocks for the market, a face-sized disc.
        context.setFillColor(CGColor(gray: scene == 1 ? 0.95 : 0.1, alpha: 0.8))
        for i in 0..<14 {
            let x = 120 + i * 70 + shift * 12
            switch scene {
            case 0: context.fill(CGRect(x: x, y: 300, width: 18, height: 220))
            case 1: context.fill(CGRect(x: x, y: 120 + (i % 3) * 160, width: 50, height: 50))
            default: context.fillEllipse(in: CGRect(x: 420 + shift * 10, y: 220, width: 360, height: 360))
            }
        }
        guard var image = context.makeImage() else { return }
        if soft, let small = CGContext(data: nil, width: width / 4, height: height / 4, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            small.interpolationQuality = .high
            small.draw(image, in: CGRect(x: 0, y: 0, width: width / 4, height: height / 4))
            if let tiny = small.makeImage() {
                context.interpolationQuality = .high
                context.draw(tiny, in: CGRect(x: 0, y: 0, width: width, height: height))
                image = context.makeImage() ?? image
            }
        }
        let date = String(format: "2026:10:26 10:%02d:%02d", second / 60, second % 60)
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// Keep sample files and the resulting Edit In copy within the snapshot run.
    private static func fixtures(in folder: URL) -> URL {
        let directory = folder.appendingPathComponent("fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A synthetic 3000x2000 photo, imported into the snapshot catalog.
    static func importSamplePhoto(into model: LibraryModel, at url: URL) async {
        let width = 3000, height = 2000
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        let colors = [CGColor(srgbRed: 0.2, green: 0.35, blue: 0.6, alpha: 1),
                      CGColor(srgbRed: 0.85, green: 0.7, blue: 0.45, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return }
        // Camera settings for the line under the histogram.
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 50.0,
                kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 1.0 / 250,
                kCGImagePropertyExifLensModel: "NIKKOR Z 50mm f/1.8 S",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON Z f"]
                as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        model.runImport(sources: [url], options: ImportOptions())
        for _ in 0..<60 where model.rows.isEmpty || model.importProgress != nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("SNAPSHOT: catalog has \(model.rows.count) photo(s)")
    }

    /// Renders a layer-backed AppKit view, such as the splash, at 2x.
    private static func capture(_ view: NSView, to url: URL) {
        let window = NSWindow(contentRect: CGRect(origin: offScreen, size: view.bounds.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(view.bounds.width * 2), height: Int(view.bounds.height * 2),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        if let image = context.makeImage() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Settings > Storage (AT-079a) with a connected share, an offline drive, a subfolder location
    /// and a share not connected yet; Add Location's three steps; the sidebar's Locations.
    static func snapshotStorage(model: LibraryModel, into folder: URL) async {
        let catalog = model.catalog
        let share = MountedVolume(identityKey: "uuid:SNAPSHOT-MEGHAM", name: "Photos", kind: .nas,
                                  rootURL: URL(fileURLWithPath: "/Volumes/Photos", isDirectory: true),
                                  serverAddress: "smb://megham.local/Photos")
        let drive = MountedVolume(identityKey: "uuid:SNAPSHOT-SSD", name: "Photos SSD", kind: .local,
                                  rootURL: URL(fileURLWithPath: "/Volumes/Photos SSD", isDirectory: true))
        // Cloud drive folders (AT-079b): one synced, one whose app has signed out.
        let dropbox = MountedVolume(identityKey: "cloud:Dropbox", name: "Dropbox", kind: .cloud,
                                    rootURL: URL(fileURLWithPath: "/Users/rosh/Library/CloudStorage/Dropbox", isDirectory: true))
        let iCloud = MountedVolume(identityKey: "cloud:iCloudDrive", name: "iCloud Drive", kind: .cloud,
                                   rootURL: URL(fileURLWithPath: "/Users/rosh/Library/Mobile Documents/com~apple~CloudDocs",
                                                isDirectory: true))
        let googleDrive = MountedVolume(identityKey: "cloud:GoogleDrive-rosh@example.com", name: "Google Drive", kind: .cloud,
                                        rootURL: URL(fileURLWithPath: "/Users/rosh/Library/CloudStorage/GoogleDrive-rosh@example.com",
                                                     isDirectory: true))
        do {
            try catalog.addStorageLocation(folder: share.rootURL, on: share, name: "megham", connectAtLaunch: true)
            try catalog.addStorageLocation(folder: drive.rootURL.appendingPathComponent("Portfolio"), on: drive)
            try catalog.addStorageLocation(folder: dropbox.rootURL.appendingPathComponent("Shoots"), on: dropbox,
                                           name: "Dropbox Shoots")
            try catalog.addStorageLocation(folder: googleDrive.rootURL, on: googleDrive)
            // A bucket for backups, with made-up keys kept in memory (never the Keychain here).
            try catalog.addObjectStorageLocation(
                name: "B2 Backups",
                bucket: S3Bucket(endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!, region: "us-west-004",
                                 bucket: "rosh-atelier", prefix: "Mac"),
                credentials: S3Credentials(accessKey: "snapshot", secretKey: "snapshot"), secrets: MemorySecrets())
            try await catalog.writer.write { db in
                try db.execute(sql: "UPDATE volume SET isOnline = 0 WHERE identityKey IN ('uuid:SNAPSHOT-SSD', 'cloud:GoogleDrive-rosh@example.com')")
                var pending = StorageLocation(name: "Studio Mac", kind: .networkShare, volumeId: nil,
                                              serverAddress: "smb://studio.local/Archive")
                try pending.insert(db)
            }
        } catch {
            print("SNAPSHOT: storage sample locations failed: \(error)")
        }
        for _ in 0..<20 where model.sidebar.locations.count < 6 { try? await Task.sleep(for: .milliseconds(250)) }
        print("SNAPSHOT: storage locations \(model.sidebar.locations.map { "\($0.location.name) \($0.statusWord) \($0.detailLine) photos=\($0.photoCount)" })")
        for theme in [Theme.light, .graphite] {
            UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
            theme.apply()
            await capture(AnyView(StorageSettings().environmentObject(model).frame(width: 640)),
                          size: CGSize(width: 640, height: 1700),
                          to: folder.appendingPathComponent("settings-storage-\(theme.rawValue).png"))
        }
        UserDefaults.standard.set(Theme.light.rawValue, forKey: Theme.defaultsKey)
        Theme.light.apply()
        let savedPane = UserDefaults.standard.object(forKey: SettingsPane.defaultsKey)
        UserDefaults.standard.set(SettingsPane.storage.rawValue, forKey: SettingsPane.defaultsKey)
        await capture(AnyView(SettingsView().environmentObject(model)), size: SettingsView.size,
                      to: folder.appendingPathComponent("settings-window-storage-light.png"))
        if let savedPane { UserDefaults.standard.set(savedPane, forKey: SettingsPane.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: SettingsPane.defaultsKey) }
        let servers = [ShareBrowser.Server(name: "megham"), ShareBrowser.Server(name: "Studio Mac")]
        let steps: [(String, AddLocationSheet)] = [
            ("1-kind", AddLocationSheet(added: { _ in })),
            ("2-share", AddLocationSheet(step: .place, kind: .networkShare, address: "smb://megham.local",
                                         previewServers: servers, added: { _ in })),
            ("3-name", AddLocationSheet(step: .name, kind: .networkShare,
                                        place: .init(mounted: share, folder: share.rootURL), name: "megham",
                                        added: { _ in })),
            ("4-cloud", AddLocationSheet(step: .place, kind: .cloudFolder, previewProviders: [iCloud, dropbox, googleDrive],
                                         added: { _ in })),
            ("5-cloud-name", AddLocationSheet(step: .name, kind: .cloudFolder,
                                              place: .init(mounted: dropbox, folder: dropbox.rootURL.appendingPathComponent("Shoots")),
                                              name: "Shoots", added: { _ in })),
            ("6-s3", AddLocationSheet(step: .place, kind: .objectStorage, s3: S3Form.snapshotSample, added: { _ in })),
        ]
        for (name, sheet) in steps {
            await capture(AnyView(sheet.environmentObject(model)), size: AddLocationSheet.size,
                          to: folder.appendingPathComponent("add-location-\(name).png"))
        }
        await capture(AnyView(SidebarView().environmentObject(model).frame(width: 260)),
                      size: CGSize(width: 260, height: 620),
                      to: folder.appendingPathComponent("sidebar-locations.png"))
        // When the original changed (AT-079c part 3): Develop's banner and the Export sheet.
        let kept = OriginalChangedError(assetID: 1, fileID: 1, filename: "NZ6_9144.NEF", place: "megham", hasKeptCopy: true)
        let notKept = OriginalChangedError(assetID: 2, fileID: 2, filename: "NZ6_9152.NEF", place: "megham", hasKeptCopy: false)
        for theme in [Theme.light, .graphite] {
            UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
            theme.apply()
            await capture(AnyView(VStack(spacing: 16) {
                OriginalChangedBanner(change: kept)
                OriginalChangedBanner(change: notKept)
            }.padding(20).frame(width: 600).environmentObject(model)),
                          size: CGSize(width: 600, height: 300),
                          to: folder.appendingPathComponent("original-changed-banner-\(theme.rawValue).png"))
            var review = ChangedOriginalsReview(command: "export", items: [.init(change: kept), .init(change: notKept)],
                                                retry: { _ in })
            review.items[0].choice = .useKeptCopy
            await capture(AnyView(ChangedOriginalsSheet(review: review).environmentObject(model)),
                          size: CGSize(width: 520, height: 300),
                          to: folder.appendingPathComponent("original-changed-sheet-\(theme.rawValue).png"))
        }
        UserDefaults.standard.set(Theme.light.rawValue, forKey: Theme.defaultsKey)
        Theme.light.apply()
    }

    private static func capture(_ view: AnyView, size: CGSize, to url: URL) async {
        // Borderless, so the window isn't limited to the CI machine's small screen.
        // Off screen, so the check never shows a window on Rosh's display.
        let window = NSWindow(contentRect: CGRect(origin: offScreen, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        // cacheDisplay draws only the view, not the window's background behind it, so paint that in.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.setContentSize(size)
        window.setFrameOrigin(offScreen)
        window.orderFrontRegardless()
        // Let SwiftUI lay out and AppKit controls settle.
        try? await Task.sleep(for: .seconds(2))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}
#else
/// Release builds have no snapshot runs (AT-076 B2).
enum LayoutSnapshots {
    static var outputFolder: URL? { nil }
}
#endif
