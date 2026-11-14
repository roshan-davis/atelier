import AgentActions
import AppKit
import AtelierActions
import AtelierCore
import SwiftUI

@main
struct AtelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var launch = CatalogLaunch()

    var body: some Scene {
        WindowGroup("Atelier") {
            Group {
                if let model = launch.model {
                    ContentView()
                        .environmentObject(model)
                        .onAppear {
                            appDelegate.model = model
                            LegacyHDRReceipts.importPending(into: model)
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
            // Atelier is one library window: File > New Window would open a second copy of the
            // same library (one shared model, keys and renders tied to the first window).
            CommandGroup(replacing: .newItem) {}
            LibraryCommands(model: launch.model)
            CommandGroup(replacing: .help) {
                // Help works before a catalog opens (the recovery screen), so it is not a
                // registry action, and it means nothing to an agent.
                Button("Atelier Help") { HelpWindow.shared.show() }  // not an action: works without a catalog
                    .keyboardShortcut("?", modifiers: [.command])
                if let model = launch.model {
                    model.actions.button(AtelierAction.keyboardShortcuts)
                } else {
                    Button("Keyboard Shortcuts") {}.disabled(true)  // not an action: no catalog open
                }
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
    // Read so the menu redraws its checkmarks when these change.
    @AppStorage(DevelopFrameHUD.preference) private var showFrameHUD = false
    @AppStorage(Filmstrip.visibleKey) private var filmstripVisible = true
    @ObservedObject var model: LibraryModel

    // Every item comes from an `AtelierAction` (see LibraryModel+Actions.swift), so the menus,
    // keys and agent catalog can't drift apart. AtelierActionsTests fail on a bare Button here.
    private var actions: AtelierRegistry { model.actions }

    var body: some Commands {
            CommandGroup(after: .newItem) {
                actions.button(AtelierAction.importPhotos)
                actions.button(AtelierAction.export)
                Divider()
                // ⌘S saves in HDR mode; elsewhere it stays Library > Write XMP for Selection.
                actions.button(AtelierAction.saveHDR)
                actions.button(AtelierAction.saveHDRAsNew)
            }
            // Undo and redo step through the open photo's develop history; text fields keep
            // their own undo.
            CommandGroup(replacing: .undoRedo) {
                actions.button(AtelierAction.undo)
                actions.button(AtelierAction.redo)
            }
            CommandGroup(after: .toolbar) {
                actions.button(AtelierAction.zoomIn)
                actions.button(AtelierAction.zoomOut)
                actions.button(AtelierAction.zoomToFit)
                actions.button(AtelierAction.zoomTo100)
                // Z itself is handled by the culling key monitor.
                actions.button(AtelierAction.toggleZoom)
                Divider()
                actions.toggle(AtelierAction.showFilmstrip)
                actions.toggle(AtelierAction.showNotes)
                Divider()
                // Only when an import or collection is private. Leaving Hide asks for Touch ID or
                // the login password (see PrivatePhotos).
                if model.sidebar.privateListCount > 0 {
                    Picker("Private Photos", selection: Binding(get: { model.filter.privacy }, set: {
                        actions.run(AtelierAction.privatePhotos, PrivacyParameters(visibility: $0.choice))
                    })) {
                        Text("Hide Private Photos").tag(PrivateVisibility.hidden)
                        Text(model.filter.showsPrivate ? "Show Private Photos" : "Show Private Photos…")
                            .tag(PrivateVisibility.shown)
                        Text(model.filter.showsPrivate ? "Show Only Private Photos" : "Show Only Private Photos…")
                            .tag(PrivateVisibility.only)
                    }
                    .pickerStyle(.inline)
                }
            }
            CommandMenu("Library") {
                actions.button(AtelierAction.grid)
                actions.button(AtelierAction.loupe)
                actions.button(AtelierAction.develop)
                Divider()
                actions.button(AtelierAction.cullImport)
                Divider()
                actions.button(AtelierAction.writeXMP)
                actions.button(AtelierAction.writeAllXMP)
                Divider()
                actions.button(AtelierAction.refreshVolumes)
            }
            CommandMenu("Photo") {
                actions.button(AtelierAction.createVirtualCopy)
                actions.button(AtelierAction.removeVirtualCopy)
                // Delete itself is handled by the key monitor, so text fields keep their Delete key.
                actions.button(AtelierAction.removePhoto, title: "Remove Photo… (Delete)")
                Divider()
                actions.button(AtelierAction.showCullGroup)
                Divider()
                actions.button(AtelierAction.addNote)
                Divider()
                // Lightroom's key for Photo Merge > HDR.
                actions.button(AtelierAction.hdr)
                Menu("Edit In") {
                    ForEach(Array(model.externalEditors.enumerated()), id: \.element.id) { index, editor in
                        actions.button(AtelierAction.editIn, EditorParameters(editor: editor.appPath),
                                       title: "Edit in \(editor.name)", showsShortcut: index == 0)
                    }
                    Divider()
                    actions.button(AtelierAction.editInOther)
                }
                .disabled(model.focusedID == nil)
                Divider()
                actions.button(AtelierAction.matchLook)
                Divider()
                ForEach(AIRecipe.allCases, id: \.self) { recipe in
                    actions.button(AtelierAction.ai, RecipeParameters(recipe: recipe.rawValue), title: "\(recipe.title)…")
                }
            }
            CommandMenu("Develop") {
                actions.toggle(AtelierAction.frameDiagnostics)
                Divider()
                actions.button(AtelierAction.copySettings)
                actions.button(AtelierAction.pasteSettings)
                Divider()
                actions.button(AtelierAction.resetAll)
                // The \ and Y keys themselves are handled by the culling key monitor.
                actions.button(AtelierAction.autoWhiteBalance)
                actions.button(AtelierAction.whiteBalanceSelector)
                actions.button(AtelierAction.crop)
                actions.button(AtelierAction.rotateLeft)
                actions.button(AtelierAction.rotateRight)
                Divider()
                actions.button(AtelierAction.showBefore)
                actions.button(AtelierAction.showClipping)
                Menu(AtelierAction.compareMode.descriptor.title) {
                    ForEach(CompareMode.allCases, id: \.self) { mode in
                        actions.button(AtelierAction.compareMode,
                                       CompareParameters(mode: CompareChoice(rawValue: mode.rawValue) ?? .off),
                                       title: mode.label)
                    }
                }
                .disabled(model.mode != .develop)
                Divider()
                actions.button(AtelierAction.newPreset)
                actions.button(AtelierAction.managePresets)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LibraryModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No window tabs: removes View > Show Tab Bar / Show All Tabs and the Window menu's tab
        // items. Set before any window (the splash included) is created.
        MainActor.assumeIsolated {
            NSWindow.allowsAutomaticWindowTabbing = false
            SplashController.shared.showAtLaunch()
        }
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

    /// Unsaved HDR changes are asked about before quitting, as in any Mac editor.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model else { return .terminateNow }
            let now = model.shouldTerminateWithHDR { quit in sender.reply(toApplicationShouldTerminate: quit) }
            return now ? .terminateNow : .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = MainActor.assumeIsolated {
            model?.rememberCurrentPhotoZoom()
            model?.saveSession()
            model?.agents.stop(quitting: true)
            let keep = UserDefaults.standard.object(forKey: "backups.keep") as? Int ?? 10
            try? model?.catalog.snapshot(keep: max(1, keep))
        }
    }
}
