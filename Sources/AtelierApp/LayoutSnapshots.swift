import AppKit
import AtelierCore
import SwiftUI

/// Renders the main window in Develop at a few window sizes to images, so layout can be checked
/// on CI without a person at the Mac. Runs when ATELIER_SNAPSHOTS names an output folder.
@MainActor
enum LayoutSnapshots {
    static let sizes: [CGSize] = [CGSize(width: 1000, height: 640), CGSize(width: 1280, height: 800),
                                  CGSize(width: 1728, height: 1117)]

    static var outputFolder: URL? {
        ProcessInfo.processInfo.environment["ATELIER_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: LibraryModel, into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let panels = ["histogram"] + DevelopSettings.Panel.allCases.map(\.rawValue)
        UserDefaults.standard.set(panels.joined(separator: ","), forKey: "develop.expandedPanels")
        UserDefaults.standard.removeObject(forKey: "panel.width")
        model.mode = .develop
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
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent(name + ".png"))
            }
            window.orderOut(nil)
        }
        fflush(stdout)
        exit(0)
    }
}
