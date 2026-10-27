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
                                   (.vignette, -30), (.grain, 40)] {
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
        UserDefaults.standard.removeObject(forKey: Theme.defaultsKey)
        Theme.system.apply()
        fflush(stdout)
        exit(0)
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
            try? await Task.sleep(for: .seconds(2))
            print("SNAPSHOT: pair entry count \(entry.photoCount), rows \(model.rows.map { "\($0.filename) paired=\($0.pairedFormats ?? "-")" })")
            await capture(AnyView(ContentView().environmentObject(model)), size: CGSize(width: 1000, height: 584),
                          to: folder.appendingPathComponent("raw-pair-grid.png"))
            model.sidebarSelection = .all
        } else {
            print("SNAPSHOT: pair import entry missing")
        }
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
