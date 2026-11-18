import AppKit
import AtelierCore
import Foundation
import SwiftUI

/// The last catalog backup to the backup location, for Settings > Storage > Backups. Kept in
/// this Mac's defaults; holds the location's name, never its address or keys.
struct CatalogBackupRecord: Codable, Equatable {
    var date: Date
    var location: String
    var bytes: Int64
    /// Nil when it worked.
    var error: String?
    /// When the last one that worked was, for the schedule.
    var lastSuccess: Date?

    static let key = "storage.lastBackup"

    static func load() -> CatalogBackupRecord? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// File > Back Up Catalog and the backup when Atelier quits (AT-079e): a copy of the catalog to the
/// location chosen in Settings > Storage > Backups, a folder or a bucket, keeping the newest N.
extension LibraryModel {
    static let backupScheduleKey = "storage.backupSchedule"
    static let backupKeepKey = "storage.backupKeep"

    var backupSchedule: BackupSchedule {
        UserDefaults.standard.string(forKey: Self.backupScheduleKey).flatMap(BackupSchedule.init(rawValue:)) ?? .daily
    }

    var remoteBackupsToKeep: Int {
        let kept = UserDefaults.standard.integer(forKey: Self.backupKeepKey)
        return kept > 0 ? kept : 10
    }

    /// The location chosen in Settings > Storage > Backups, if it still exists.
    func backupLocation() -> StorageLocationInfo? {
        guard let id = try? catalog.backupLocationID() else { return nil }
        return (try? catalog.storageLocations())?.first { $0.id == id }
    }

    /// Backs the catalog up now. `done` gets whether it worked (also when there's nothing to do).
    func backUpCatalog(done: (@MainActor (Bool) -> Void)? = nil) {
        guard backupJob == nil else { return }
        let catalog = self.catalog
        guard let info = backupLocation() else {
            status = "Choose where to back up the catalog in Settings > Storage > Backups."
            done?(false)
            return
        }
        let locationID = info.id
        let name = info.location.name
        let keep = remoteBackupsToKeep
        let previousSuccess = lastBackup?.lastSuccess
        backupProgress = ImportStatus(phase: "Backing up the catalog to \(name)", fraction: nil)
        backupJob = Task { [weak self] in
            let relay = ProgressRelay { [weak self] permille in
                guard let self, self.backupProgress != nil else { return }
                self.backupProgress = ImportStatus(phase: "Backing up the catalog to \(name)", fraction: Double(permille) / 1000)
            }
            let run = Task.detached(priority: .utility) { () -> Swift.Result<CatalogBackups.Result, Error> in
                do {
                    let destination = try catalog.backupDestination(for: locationID)
                    return .success(try await CatalogBackups.run(catalog, to: destination, keep: keep) { relay.send(Int64($0 * 1000)) })
                } catch {
                    return .failure(error)
                }
            }
            let result = await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
            guard let self else { return }
            self.backupProgress = nil
            self.backupJob = nil
            let record: CatalogBackupRecord
            switch result {
            case .success(let backup):
                record = CatalogBackupRecord(date: Date(), location: name, bytes: backup.bytes, error: nil, lastSuccess: Date())
                self.status = "Backed up the catalog to \(name) (\(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file)))."
            case .failure(let error):
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                record = CatalogBackupRecord(date: Date(), location: name, bytes: 0,
                                             error: cancelled ? "Skipped." : error.localizedDescription, lastSuccess: previousSuccess)
                self.status = cancelled ? "Catalog backup cancelled." : "Couldn't back up the catalog to \(name): \(error.localizedDescription)"
            }
            record.save()
            self.lastBackup = record
            if case .success = result { done?(true) } else { done?(false) }
        }
    }

    func cancelCatalogBackup() {
        backupJob?.cancel()
    }

    /// Before quitting: when a backup to the backup location is due, runs it in a small window
    /// with progress and Skip (as Lightroom's), then calls `done`. Returns false, without calling
    /// `done`, when none is due.
    func backUpBeforeQuitting(done: @escaping @MainActor () -> Void) -> Bool {
        guard backupJob == nil, backupLocation() != nil,
              backupSchedule.isDue(last: lastBackup?.lastSuccess) else { return false }
        let panel = QuitBackupPanel(model: self)
        backUpCatalog { _ in
            panel.close()
            done()
        }
        panel.show()
        return true
    }
}

/// "Backing Up Catalog" while Atelier quits: what it's doing, a bar, and Skip This Time.
@MainActor
final class QuitBackupPanel {
    private var window: NSPanel?
    private let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    func show() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Backing Up Catalog"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: QuitBackupView().environmentObject(model))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }

    func close() {
        window?.close()
        window = nil
    }
}

private struct QuitBackupView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.backupProgress?.phase ?? "Backing up the catalog")
                .lineLimit(1)
            if let fraction = model.backupProgress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text("Atelier quits when it's done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip This Time") { model.cancelCatalogBackup() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
