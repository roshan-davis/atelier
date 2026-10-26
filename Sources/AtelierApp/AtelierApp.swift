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
                Button("Export…") { model.beginExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Zoom to Fit") { model.zoom = .fit }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("Zoom to 100%") { model.zoom = .percent(100) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                // Z itself is handled by the culling key monitor.
                Button("Toggle Zoom (Z)") { model.toggleZoom() }
                Divider()
            }
            CommandMenu("Library") {
                Button("Grid") { model.mode = .grid }
                    .keyboardShortcut("g", modifiers: [.command])
                Button("Loupe") { model.openLoupe() }
                    .keyboardShortcut("e", modifiers: [.command])
                Button("Develop") { model.openDevelop() }
                    .keyboardShortcut("d", modifiers: [.command])
                Divider()
                Button("Write XMP for Selection") { model.writeXMP(selectionOnly: true) }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Write All Unsaved XMP") { model.writeXMP(selectionOnly: false) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Refresh Volumes") { model.refreshVolumes() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            CommandMenu("Develop") {
                Button("Copy Settings") { model.copyDevelopSettings() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Paste Settings") { model.pasteDevelopSettings() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Reset All Settings") { model.develop.resetAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.mode != .develop)
                // The \ and Y keys themselves are handled by the culling key monitor.
                Button("Show Before (\\)") { model.develop.showingBefore.toggle() }
                    .disabled(model.mode != .develop)
                Menu("Before and After (Y)") {
                    ForEach(CompareMode.allCases, id: \.self) { mode in
                        Button(mode.label) { model.develop.compareMode = mode }
                    }
                }
                .disabled(model.mode != .develop)
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
