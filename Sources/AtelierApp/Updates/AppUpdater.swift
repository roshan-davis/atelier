import AppKit
import AtelierCore
import Combine
import Sparkle

/// Atelier's updater (AT-087, PRD "Updates and distribution"): Sparkle 2 reading the appcast
/// on GitHub. The one place the app talks to Sparkle, so an App Store build can leave it out.
///
/// Off (no Sparkle object at all, so no check and no window) unless the app runs from an app
/// bundle whose Info.plist names a feed and an EdDSA public key, which only
/// `Scripts/build_macos_app.py` writes. Builds run from Xcode and test runs never check.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    static let includeBetaKey = "updates.includeBeta"
    /// How this copy was signed, written by the build script: developerID, selfSigned or adhoc.
    static let signingKey = "AtelierSigning"

    /// Whether this copy can update itself at all.
    let isEnabled: Bool
    /// Whether this copy may install updates without asking (Developer ID builds; see PRD).
    let allowsAutomaticInstall: Bool

    @Published private(set) var canCheck = false
    /// A newer version Sparkle found but didn't show (a background check mid-session).
    @Published private(set) var pendingVersion: String?
    @Published private(set) var lastCheck: Date?
    @Published var checksAutomatically = false {
        didSet { if controller?.updater.automaticallyChecksForUpdates != checksAutomatically { controller?.updater.automaticallyChecksForUpdates = checksAutomatically } }
    }
    @Published var installsAutomatically = false {
        didSet { if controller?.updater.automaticallyDownloadsUpdates != installsAutomatically { controller?.updater.automaticallyDownloadsUpdates = installsAutomatically } }
    }

    private var controller: SPUStandardUpdaterController?

    private override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        isEnabled = Bundle.main.bundleURL.pathExtension == "app" && feed != nil && !key.isEmpty
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        allowsAutomaticInstall = (info[Self.signingKey] as? String) == "developerID"
        super.init()
    }

    /// Starts the updater once, at launch. Sparkle then checks on its own schedule (daily).
    func start() {
        guard isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                      userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            NSLog("Atelier updates could not start: %@", error.localizedDescription)
            return
        }
        // Sparkle's own SwiftUI pattern: the menu item and Check Now follow canCheckForUpdates.
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        lastCheck = updater.lastUpdateCheckDate
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = allowsAutomaticInstall && updater.automaticallyDownloadsUpdates
    }

    /// Atelier > Check for Updates… and Settings > Updates > Check Now: always shows the result.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var includesBeta: Bool {
        get { UserDefaults.standard.bool(forKey: Self.includeBetaKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.includeBetaKey)
            // Look again now, quietly, so a beta shows up without waiting a day.
            if newValue, let updater = controller?.updater, updater.canCheckForUpdates {
                updater.checkForUpdatesInBackground()
            }
        }
    }

    /// "1.3.0 (1482)" for this copy; "Development build" from Xcode.
    static var currentVersionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String,
              Bundle.main.bundleURL.pathExtension == "app" else { return "Development build" }
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// The menu item's title: "Update Available: 1.3.0…" while a found update waits.
    var menuTitle: String {
        pendingVersion.map { "Update Available: \($0)…" } ?? "Check for Updates…"
    }
}

extension AppUpdater: @preconcurrency SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesBeta ? ["beta"] : []
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        pendingVersion = nil
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    /// A background check mid-session never opens a window over the person's work: it marks the
    /// menu item instead, and the window opens when they choose it (PRD "Checking").
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        pendingVersion = handleShowingUpdate ? nil : update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
