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
        for (name, size, view) in shots {
            // Borderless, so the window isn't limited to the CI machine's small screen.
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.setContentSize(size)
            window.orderFront(nil)
            // Let SwiftUI lay out and AppKit controls settle.
            try? await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent(name + ".png"))
            }
            window.orderOut(nil)
        }
        // The app's real window too, with its toolbar, at the size in Rosh's screenshot.
        if let window = model.mainWindow, let frameView = window.contentView?.superview {
            window.setContentSize(CGSize(width: 1000, height: 584))
            try? await Task.sleep(for: .seconds(2))
            if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("window-1000x584.png"))
            }
        }
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
}
