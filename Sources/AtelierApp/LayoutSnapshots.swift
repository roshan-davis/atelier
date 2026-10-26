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
