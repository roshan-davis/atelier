import AppKit
import AtelierCore
import Combine
import SwiftUI

/// Keeps the library absent until the real catalog opens successfully.
@MainActor
final class CatalogLaunch: ObservableObject {
    let opening: CatalogOpening

    init(packageURL: URL? = nil) {
        #if DEBUG
        // Disposable-catalog override for recovery checks; never changes the normal location.
        let path = ProcessInfo.processInfo.environment["ATELIER_CATALOG_PATH"]
            ?? Bundle.main.object(forInfoDictionaryKey: "AtelierTestCatalogPath") as? String
        opening = CatalogOpening(packageURL: packageURL ?? path.map { URL(fileURLWithPath: $0) } ?? Catalog.defaultPackageURL)
        #else
        opening = CatalogOpening(packageURL: packageURL ?? Catalog.defaultPackageURL)
        #endif
    }
    @Published private(set) var model: LibraryModel?
    private(set) var task: Task<Void, Never>?

    func open() {
        guard task == nil, model == nil else { return }
        task = Task {
            defer { task = nil }
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["ATELIER_METADATA_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                await LayoutSnapshots.snapshotMetadata(into: folder)
                NSApp.terminate(nil)
                return
            }
            if let path = ProcessInfo.processInfo.environment["ATELIER_RECOVERY_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                await LayoutSnapshots.snapshotCatalogRecovery(into: folder)
                NSApp.terminate(nil)
                return
            }
            #endif
            let splash = SplashController.shared
            splash.report("Opening catalog “\(opening.packageURL.deletingPathExtension().lastPathComponent)”…", progress: 0.15)
            await opening.open()
            guard let catalog = opening.catalog else {
                splash.dismiss()
                return
            }
            let library = LibraryModel(catalog: catalog, report: { splash.report($0, progress: $1) })
            library.onLibraryLoaded = { sidebar in
                var text = sidebar.totalCount == 0 ? "Ready" : "Ready · \(sidebar.totalCount.formatted()) photo\(sidebar.totalCount == 1 ? "" : "s")"
                let offline = sidebar.volumes.filter { !$0.isOnline }.map(\.name)
                if !offline.isEmpty { text += " · \(ListFormatter.localizedString(byJoining: offline)) offline" }
                splash.finishLaunch(text)
            }
            #if DEBUG
            // The native smoke test boots with a seeded catalog and uses real controls from here.
            let environment = ProcessInfo.processInfo.environment
            if environment["ATELIER_UI_SMOKE"] == "1", environment["ATELIER_CATALOG_PATH"] != nil {
                UserDefaults.standard.set("basic", forKey: "develop.expandedPanels")
                await LayoutSnapshots.importSamplePhoto(
                    into: library, at: opening.packageURL.deletingLastPathComponent().appendingPathComponent("smoke.jpg")
                )
            }
            #endif
            model = library
        }
    }
}

struct CatalogRecoveryView: View {
    @ObservedObject var opening: CatalogOpening
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: opening.failureReason == nil ? "photo.on.rectangle" : "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(opening.failureReason == nil ? "Opening Catalog…" : "Couldn’t Open Catalog")
                        .font(.title2.weight(.semibold))
                    Text(opening.packageURL.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reason = opening.failureReason {
                Text(reason).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your catalog has not been replaced or reset. Check that its location is available and you have permission to access it, then try again.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Show in Finder") {
                        // Reveal the package, or the closest existing parent if it is unavailable.
                        var url = opening.packageURL
                        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
                            url.deleteLastPathComponent()
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                    Button("Try Again", action: retry).keyboardShortcut(.defaultAction)
                }
            } else {
                ProgressView().controlSize(.small)
                HStack { Spacer(); Button("Quit") { NSApp.terminate(nil) } }
            }
        }
        .padding(32)
        .frame(maxWidth: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
