import AppKit
import AtelierCore
import SwiftUI

@main
struct AtelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var launch = CatalogLaunch()

    var body: some Scene {
        WindowGroup("Lightfast") {
            Group {
                if let model = launch.model {
                    ContentView()
                        .environmentObject(model)
                        .onAppear {
                            appDelegate.model = model
                            model.processorSessions.start()
                            PanelHelp.hasTopic = { HelpWindow.topic(forPanel: $0) != nil }
                            PanelHelp.show = { title in
                                if let topic = HelpWindow.topic(forPanel: title) {
                                    HelpWindow.shared.show(page: topic.page, section: topic.section)
                                }
                            }
                            if let folder = LayoutSnapshots.outputFolder {
                                Task { await LayoutSnapshots.run(model: model, into: folder) }
                            }
                        }
                } else {
                    CatalogRecoveryView(opening: launch.opening, retry: { launch.open() })
                }
            }
            .frame(minWidth: 1000, minHeight: 640)
            .task { launch.open() }
        }
        .commands {
            LibraryCommands(model: launch.model)
            CommandGroup(replacing: .help) {
                Button("Lightfast Help") { HelpWindow.shared.show() }
                    .keyboardShortcut("?", modifiers: [.command])
                Button("Keyboard Shortcuts") { launch.model?.showingShortcuts = true }
                    .keyboardShortcut("/", modifiers: [.command])
                    .disabled(launch.model == nil)
            }
        }
        Settings {
            if let model = launch.model {
                SettingsView().environmentObject(model)
            } else {
                CatalogRecoveryView(opening: launch.opening, retry: { launch.open() })
                    .frame(width: 680, height: 480)
            }
        }
    }
}

/// Commands that require a catalog are installed only after a successful open.
struct LibraryCommands: Commands {
    var model: LibraryModel?

    var body: some Commands {
        if let model { ReadyLibraryCommands(model: model) }
    }
}

private struct ReadyLibraryCommands: Commands {
    @ObservedObject var model: LibraryModel

    var body: some Commands {
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
                // Delete itself is handled by the key monitor, so text fields keep their Delete key.
                Button("Remove Photo… (Delete)") { model.beginRemovePhotos() }
                    .disabled(model.targetIDs.isEmpty)
                Divider()
                Button("Show Cull Group") { model.showCullGroup() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.focusedCullGroupSize < 2)
                Divider()
                Menu("Edit In") {
                    Button("HDR App (Original)…") { model.editInHDR() }
                        .disabled(model.targetIDs.count != 1)
                    Divider()
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
                Button("Auto White Balance") { model.develop.findWhiteBalance() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(model.mode != .develop || model.develop.assetID == nil)
                Button("White Balance Selector (W)") { model.perform(.whiteBalance) }
                    .disabled(model.focusedID == nil)
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
                Button("Show Clipping (J)") { model.perform(.clipping) }
                    .disabled(model.mode != .develop || model.develop.assetID == nil)
                Menu("Before and After (Y)") {
                    ForEach(CompareMode.allCases, id: \.self) { mode in
                        Button(mode.label) { model.develop.compareMode = mode }
                    }
                }
                .disabled(model.mode != .develop)
                Divider()
                Button("New Preset…") { model.develop.showingNewPreset = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.mode != .develop || model.develop.assetID == nil)
                Button("Manage Presets…") { model.develop.showingManagePresets = true }
                    .disabled(model.mode != .develop)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LibraryModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { SplashController.shared.showAtLaunch() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from `swift run` the process has no bundle; make it a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        if let iconURL = AtelierResources.bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        MainActor.assumeIsolated {
            Theme.current.apply()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = MainActor.assumeIsolated {
            model?.rememberCurrentPhotoZoom()
            model?.saveSession()
            let keep = UserDefaults.standard.object(forKey: "backups.keep") as? Int ?? 10
            try? model?.catalog.snapshot(keep: max(1, keep))
        }
    }
}
