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
                .onAppear {
                    appDelegate.model = model
                    if let folder = LayoutSnapshots.outputFolder {
                        Task { await LayoutSnapshots.run(model: model, into: folder) }
                    }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Photos…") { model.beginImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export…") { model.beginExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            // Undo and redo step through the open photo's develop history; text fields keep
            // their own undo.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
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
                FilmstripMenuItem()
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
                Button("Cull Import…") {
                    if case .importGroup(let id) = model.sidebarSelection { model.beginCull(importGroup: id) }
                }
                .disabled({ if case .importGroup = model.sidebarSelection { return false } else { return true } }())
                Divider()
                Button("Write XMP for Selection") { model.writeXMP(selectionOnly: true) }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Write All Unsaved XMP") { model.writeXMP(selectionOnly: false) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Refresh Volumes") { model.refreshVolumes() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            CommandMenu("Photo") {
                Button("Create Virtual Copy") { model.createVirtualCopies() }
                    .keyboardShortcut("'", modifiers: [.command])
                    .disabled(model.focusedID == nil)
                Button("Remove Virtual Copy…") { model.removeVirtualCopies() }
                    .disabled(!model.targetsIncludeVirtualCopy)
                Divider()
                Button("Show Cull Group") { model.showCullGroup() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.focusedCullGroupSize < 2)
                Divider()
                Menu("Edit In") {
                    ForEach(Array(model.externalEditors.enumerated()), id: \.element.id) { index, editor in
                        if index == 0 {
                            Button("Edit in \(editor.name)") { model.editIn(editor) }
                                .keyboardShortcut("e", modifiers: [.command, .option])
                        } else {
                            Button("Edit in \(editor.name)") { model.editIn(editor) }
                        }
                    }
                    Divider()
                    Button("Other Application…") { model.editInOtherApp() }
                }
                .disabled(model.focusedID == nil)
                Divider()
                Button("Match Look to Reference…") { model.beginMatchLook() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.mode != .develop || model.focusedID == nil)
                Divider()
                ForEach(AIRecipe.allCases, id: \.self) { recipe in
                    Button("\(recipe.title)…") { model.openAI(recipe) }
                        .disabled(model.focusedID == nil)
                }
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.showingShortcuts = true }
                    .keyboardShortcut("/", modifiers: [.command])
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
                Button("Crop & Straighten (R)") { model.perform(.crop) }
                    .disabled(model.focusedID == nil)
                Button("Rotate Left") { model.rotate(clockwise: false) }
                    .keyboardShortcut("[", modifiers: [.command])
                    .disabled(model.mode != .develop)
                Button("Rotate Right") { model.rotate(clockwise: true) }
                    .keyboardShortcut("]", modifiers: [.command])
                    .disabled(model.mode != .develop)
                Divider()
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

        // Atelier > Settings… (⌘,)
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LibraryModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from `swift run` the process has no bundle; make it a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        MainActor.assumeIsolated {
            Theme.current.apply()
            if LayoutSnapshots.outputFolder == nil { SplashController.shared.showAtLaunch() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = MainActor.assumeIsolated {
            let keep = UserDefaults.standard.object(forKey: "backups.keep") as? Int ?? 10
            try? model?.catalog.snapshot(keep: max(1, keep))
        }
    }
}
