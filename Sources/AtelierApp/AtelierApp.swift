import AppKit
import AtelierCore
import SwiftUI

@main
struct AtelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LibraryModel()

    var body: some Scene {
        WindowGroup("Atelier") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Photos…") { model.beginImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Library") {
                Button("Grid") { model.mode = .grid }
                    .keyboardShortcut("g", modifiers: [.command])
                Button("Loupe") { model.openLoupe() }
                    .keyboardShortcut("e", modifiers: [.command])
                Divider()
                Button("Write XMP for Selection") { model.writeXMP(selectionOnly: true) }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Write All Unsaved XMP") { model.writeXMP(selectionOnly: false) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Refresh Volumes") { model.refreshVolumes() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LibraryModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from `swift run` the process has no bundle; make it a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = MainActor.assumeIsolated {
            try? model?.catalog.snapshot()
        }
    }
}
