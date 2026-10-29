import AppKit
import ImageIO
import AtelierCore
import SwiftUI

/// Renders the main window in Develop at a few window sizes to images, so layout can be checked
/// on CI without a person at the Mac. Runs when ATELIER_SNAPSHOTS names an output folder.
@MainActor
enum LayoutSnapshots {
    // 1000x584 is the window in Rosh's screenshot.
    static let sizes: [CGSize] = [CGSize(width: 1000, height: 584), CGSize(width: 1000, height: 640), CGSize(width: 1280, height: 800),
                                  CGSize(width: 1728, height: 1117)]

    static var outputFolder: URL? {
        ProcessInfo.processInfo.environment["ATELIER_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: LibraryModel, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await importSamplePhoto(into: model)
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
        await snapshotSliderPreviews(model: model, into: folder)
        await snapshotColorGrading(model: model, into: folder)
        await snapshotMatchLook(model: model, into: folder)
        await snapshotMasking(model: model, into: folder)
        await snapshotTransform(model: model, into: folder)
        await snapshotPresets(model: model, into: folder)
        // Each theme in Develop at the size in Rosh's screenshot, and the theme picker itself.
        for theme in Theme.allCases where theme != .system {
            UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
            theme.apply()
            await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                          to: folder.appendingPathComponent("theme-\(theme.rawValue).png"))
        }
        model.mode = .grid
        // Edit In end to end, with Preview standing in for Photoshop: the copy is stacked next to the original.
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
        await snapshotRawPair(model: model, into: folder)
        await capture(AnyView(ImportSettings().frame(width: 560)), size: CGSize(width: 560, height: 420),
                      to: folder.appendingPathComponent("settings-import.png"))
        await capture(AnyView(AppearanceSettings().frame(width: 560)), size: CGSize(width: 560, height: 330),
                      to: folder.appendingPathComponent("settings-appearance.png"))
        await capture(AnyView(EditInSettings().frame(width: 640)), size: CGSize(width: 640, height: 360),
                      to: folder.appendingPathComponent("settings-editin.png"))
        await capture(AnyView(AISettingsTab().frame(width: 640)), size: CGSize(width: 640, height: 600),
                      to: folder.appendingPathComponent("settings-ai.png"))
        await capture(AnyView(GeneralSettings().environmentObject(model).frame(width: 640)), size: CGSize(width: 640, height: 640),
                      to: folder.appendingPathComponent("settings-general.png"))
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

    /// The Presets panel with groups open and the Amount slider, a B&W pack preset on the photo,
    /// and the Create Preset and Manage Presets dialogs.
    private static func snapshotPresets(model: LibraryModel, into folder: URL) async {
        let develop = model.develop
        UserDefaults.standard.set("pack:Film\npack:Black & White", forKey: "presets.toggledGroups")
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
        if let highContrast = develop.presets.first(where: { $0.name == "High Contrast" }) {
            develop.applyPreset(highContrast)
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
        develop.resetAll()
        develop.flushSave()
    }

    /// The Match Look dialog with a warm, teal-shadowed reference, then with Match Areas on.
    private static func snapshotMatchLook(model: LibraryModel, into folder: URL) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-reference.jpg")
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
        func waitForMatch() async {
            try? await Task.sleep(for: .milliseconds(500))
            for _ in 0..<60 where match.match == nil || match.isMatching { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(1))
        }
        await waitForMatch()
        print("SNAPSHOT: match look \(match.match.flatMap { try? $0.matched.encoded() } ?? "none"), message \(match.message ?? "-")")
        await capture(AnyView(MatchLookSheet(match: match).environmentObject(model)), size: CGSize(width: 900, height: 660),
                      to: folder.appendingPathComponent("match-look.png"))
        await capture(AnyView(MatchDifferencesView(lines: match.differences)), size: CGSize(width: 300, height: 420),
                      to: folder.appendingPathComponent("match-look-differences.png"))
        match.usesAreas = true
        match.photoArea = CGRect(x: 0.1, y: 0.15, width: 0.35, height: 0.3)
        await waitForMatch()
        await capture(AnyView(MatchLookSheet(match: match).environmentObject(model)), size: CGSize(width: 900, height: 660),
                      to: folder.appendingPathComponent("match-look-areas.png"))
        model.matchLook = nil
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
                          size: CGSize(width: 320, height: view == "3-Way" ? 560 : 520),
                          to: folder.appendingPathComponent("color-grading-\(view.lowercased())-320.png"))
        }
        UserDefaults.standard.set("3-Way", forKey: "develop.gradeView")
        develop.setPanelOn(.colorGrading, false)
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-grading-off-1280x800.png"))
        develop.setPanelOn(.colorGrading, true)
        develop.isPickingGradeColor = true
        try? await Task.sleep(for: .seconds(1))
        await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1280, height: 800),
                      to: folder.appendingPathComponent("develop-grading-picker-1280x800.png"))
        develop.isPickingGradeColor = false
        develop.reset(.gradeMidtonesLum)
        develop.reset(.gradeBalance)
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

    /// Culling before an import: three takes of one scene (one soft), two of another, and a
    /// single shot. Captures the Cull view, then imports and prints how the photos landed.
    private static func snapshotCulling(model: LibraryModel, into folder: URL) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-cull-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shots: [(String, Int, Int, Bool)] = [("Beach-1", 0, 0, false), ("Beach-2", 0, 1, true), ("Beach-3", 0, 2, false),
                                                 ("Market-1", 1, 20, false), ("Market-2", 1, 21, false), ("Portrait", 2, 300, false)]
        var files: [URL] = []
        for (name, scene, second, soft) in shots {
            let url = dir.appendingPathComponent(name + ".jpg")
            writeScene(scene, shift: second % 3, soft: soft, second: second, to: url)
            files.append(url)
        }
        let cull = CullModel(source: .importing(files: files, options: ImportOptions(target: .newGroup(name: "Cull Test"))),
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

    /// A RAW+JPEG pair (the "RAW" is a JPEG renamed; the catalog goes by name) next to a lone
    /// JPEG: the grid shows two photos, the RAW marked RAW+JPG.
    private static func snapshotRawPair(model: LibraryModel, into folder: URL) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-pair-\(UUID().uuidString)")
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

    /// A synthetic 3000x2000 photo, imported into the snapshot catalog.
    private static func importSamplePhoto(into model: LibraryModel) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-snapshot.jpg")
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
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        model.runImport(sources: [url], options: ImportOptions())
        for _ in 0..<60 where model.rows.isEmpty || model.importProgress != nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("SNAPSHOT: catalog has \(model.rows.count) photo(s)")
    }

    /// Renders a layer-backed AppKit view, such as the splash, at 2x.
    private static func capture(_ view: NSView, to url: URL) {
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
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

    private static func capture(_ view: AnyView, size: CGSize, to url: URL) async {
        // Borderless, so the window isn't limited to the CI machine's small screen.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        // cacheDisplay draws only the view, not the window's background behind it, so paint that in.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
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
