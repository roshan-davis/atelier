import AppKit
import AtelierCore
import LocalAuthentication

/// Private import entries and collections (AT-023): their photos appear nowhere in Atelier until
/// View > Show Private Photos… (with everything else) or Show Only Private Photos…, after Touch ID
/// or the Mac's login password. Every launch starts with them hidden, and they hide again from
/// View > Hide Private Photos, after a while without using Atelier (Settings > General > Private
/// Photos), and when the Mac sleeps or locks. The View menu lists these only when something is
/// private. It's for seeing those shoots on purpose, not security: nothing is encrypted.
@MainActor
final class PrivatePhotos {
    private weak var model: LibraryModel?
    private var lastActivity = Date()
    private var activityMonitor: Any?
    private var idleTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var asking = false

    /// Minutes without using Atelier before private photos hide again; 0 never.
    nonisolated static let hideAfterKey = "private.hideAfterMinutes"
    nonisolated static let defaultHideAfter = 10
    nonisolated static let hideAfterChoices = [5, 10, 15, 30, 60, 0]

    nonisolated static var hideAfterMinutes: Int {
        UserDefaults.standard.object(forKey: hideAfterKey) as? Int ?? defaultHideAfter
    }

    init(model: LibraryModel) {
        self.model = model
    }

    var visibility: PrivateVisibility { model?.filter.privacy ?? .hidden }
    var isShowing: Bool { visibility != .hidden }

    /// The View menu's choice. Leaving Hidden asks for Touch ID or the password; switching
    /// between Show and Show Only doesn't.
    func choose(_ choice: PrivateVisibility) {
        guard choice != visibility else { return }
        switch choice {
        case .hidden: hide()
        case .shown, .only:
            if isShowing { apply(choice) } else { unlock(then: choice) }
        }
    }

    // MARK: Show

    /// Asks for Touch ID or the login password with macOS's own prompt, as for its Hidden album.
    private func unlock(then choice: PrivateVisibility) {
        guard model != nil, !asking else { return }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            guard (error as? LAError)?.code == .passcodeNotSet else {
                model?.status = "Private photos can't be shown: \(error?.localizedDescription ?? "macOS can't ask for your password")"
                return
            }
            // No login password on this Mac, so there is nothing to ask for: confirm instead.
            let alert = NSAlert()
            alert.messageText = "Show private photos?"
            alert.informativeText = "This Mac has no login password, so Touch ID or a password can't be asked for."
            alert.addButton(withTitle: "Show")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { apply(choice) }
            return
        }
        asking = true
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "show your private photos") { [weak self] success, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.asking = false
                    if success {
                        self.apply(choice)
                    } else if let code = (error as? LAError)?.code,
                              ![.userCancel, .appCancel, .systemCancel].contains(code) {
                        self.model?.status = "Private photos weren't shown: \(error?.localizedDescription ?? "")"
                    }
                }
            }
        }
    }

    private func apply(_ choice: PrivateVisibility) {
        guard let model else { return }
        lastActivity = Date()
        // Show Only: an ordinary sidebar item has nothing left to show.
        if choice == .only { model.leavesHiddenScope = true }
        model.filter.privacy = choice
        startWatching()
        model.status = choice == .only ? "Showing only private photos." : "Private photos are shown."
    }

    // MARK: Hide

    /// View > Hide Private Photos, the sidebar's Hide Private button, idle time, sleep and the
    /// screen locking. Anything private on screen is put away first.
    func hide(because reason: String? = nil) {
        guard let model, isShowing else { return }
        stopWatching()
        model.putAwayPrivatePhotos()
        model.leavesHiddenScope = true
        model.filter.privacy = .hidden
        model.status = reason.map { "Private photos are hidden again \($0)." } ?? "Private photos are hidden."
    }

    /// Nothing is private any more: back to the normal view without a message.
    func reset() {
        guard let model, isShowing else { return }
        stopWatching()
        model.leavesHiddenScope = true
        model.filter.privacy = .hidden
    }

    // MARK: Watching for idle time and sleep

    private func startWatching() {
        guard activityMonitor == nil else { return }
        // Only Atelier's own events: time in other apps counts as not using Atelier.
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                       .scrollWheel, .magnify, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.lastActivity = Date() }
            return event
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.hide(because: "because the Mac went to sleep") }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.hide(because: "because the display went to sleep") }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.hide(because: "because you switched users") }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.hide(because: "because the screen was locked") }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.hide(because: "because the screen saver started") }
        // Coming back to Atelier after a long time away hides them before anything is drawn.
        observe(NotificationCenter.default, NSApplication.willBecomeActiveNotification) { $0.checkIdle() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (PrivatePhotos) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func stopWatching() {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        activityMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func checkIdle() {
        let minutes = Self.hideAfterMinutes
        guard isShowing, minutes > 0, Date().timeIntervalSince(lastActivity) >= Double(minutes) * 60 else { return }
        hide(because: "after \(minutes) minutes without using Atelier")
    }
}

extension LibraryModel {
    /// Right-click an import entry or collection > Make Private… / Make Not Private.
    func setPrivate(_ isPrivate: Bool, importGroup id: Int64) {
        let name = sidebar.imports.first { $0.id == id }?.name ?? "The import"
        changePrivate(isPrivate, name: name) { try $0.setImportGroup(id, isPrivate: isPrivate) }
    }

    func setPrivate(_ isPrivate: Bool, collection id: Int64) {
        let name = sidebar.collections.first { $0.id == id }?.name ?? "The collection"
        changePrivate(isPrivate, name: name) { try $0.setCollection(id, isPrivate: isPrivate) }
    }

    private func changePrivate(_ isPrivate: Bool, name: String, _ change: (Catalog) throws -> Void) {
        // Before the change, so the sidebar data that first lacks the list leaves it.
        if isPrivate, !privatePhotos.isShowing { leavesHiddenScope = true }
        do {
            try change(catalog)
        } catch {
            status = error.localizedDescription
            return
        }
        if isPrivate {
            // Hidden now: nothing private may stay open or selected.
            if !privatePhotos.isShowing {
                putAwayPrivatePhotos()
                reloadDetail()
            }
            announcePrivate(name)
        } else {
            status = "\u{201C}\(name)\u{201D} isn't private any more."
        }
    }

    private func announcePrivate(_ name: String) {
        status = privatePhotos.isShowing
            ? "\u{201C}\(name)\u{201D} is private."
            : "\u{201C}\(name)\u{201D} is private and hidden. View > Show Private Photos… shows it."
    }

    /// Before private photos hide: leaves a private import or collection for All Photographs, and
    /// when a private photo is open or selected, goes back to the grid and closes the dialogs
    /// that show it (Export, Match Look, Remove Photo, Cull). Loupe and Develop keep the last
    /// photo on screen until the next is ready, so they must not stay on a private one.
    func putAwayPrivatePhotos() {
        switch sidebarSelection {
        case .importGroup(let id)? where sidebar.imports.first(where: { $0.id == id })?.isPrivate == true:
            sidebarSelection = .all
        case .collection(let id)? where sidebar.collections.first(where: { $0.id == id })?.isPrivate == true:
            sidebarSelection = .all
        default:
            break
        }
        if let deletion = deletingImport, sidebar.imports.first(where: { $0.id == deletion.id })?.isPrivate == true {
            deletingImport = nil
        }
        var shown = selection
        if let focusedID { shown.insert(focusedID) }
        if showingExportSheet { shown.formUnion(exportIDs) }
        if let matchLook { shown.insert(matchLook.assetID); shown.formUnion(matchLook.targets) }
        let culling: [Int64] = {
            guard let cullSession, case .photos(let ids, _) = cullSession.source else { return [] }
            return ids
        }()
        shown.formUnion(culling)
        guard let hidden = try? catalog.privatePhotoIDs(among: shown), !hidden.isEmpty else { return }
        if showingExportSheet, !hidden.isDisjoint(with: exportIDs) { showingExportSheet = false }
        if let matchLook, hidden.contains(matchLook.assetID) || !hidden.isDisjoint(with: matchLook.targets) {
            self.matchLook = nil
        }
        if !hidden.isDisjoint(with: culling) { cullSession = nil }
        if !hidden.isDisjoint(with: selection) || focusedID.map({ hidden.contains($0) }) == true {
            removal = nil
            if mode == .develop { develop.flushSave() }
            mode = .grid
            selection.subtract(hidden)
            if let focusedID, hidden.contains(focusedID) { self.focusedID = selection.first }
        }
    }

    /// The sidebar item is gone (private and now hidden, or a folder of only private photos):
    /// show All Photographs.
    func leaveMissingScope(_ data: SidebarData) {
        guard !pendingSessionScope else { return }
        let scope = SavedSession.resolveScope(filter.scope, in: (
            volumes: data.volumes.compactMap(\.id), folders: data.folders.compactMap(\.id),
            collections: data.collections.compactMap(\.id), imports: data.imports.map(\.id)))
        if scope != filter.scope { sidebarSelection = SidebarItem(scope) }
    }
}
