import Foundation
import GRDB

public struct XMPWriteResult: Sendable {
    public var written = 0
    /// On an offline volume; stays dirty and is written when the volume returns.
    public var offline = 0
    public var failures: [ImportFailure] = []
}

extension Catalog {
    /// Writes sidecars for `assetIDs`, or for every photo with unsaved changes when nil.
    public func writeXMPSidecars(for assetIDs: [Int64]? = nil) throws -> XMPWriteResult {
        XMPSidecar.writeLock.lock()
        defer { XMPSidecar.writeLock.unlock() }
        // A virtual copy shares its master's file, so only the master writes the sidecar.
        let (jobs, copies): ([(Int64, URL?, XMPFields, DevelopSettingsRecord?)], [Int64]) = try writer.read { db in
            let ids = try assetIDs ?? Int64.fetchAll(db, sql: "SELECT assetId FROM metadata WHERE xmpDirty = 1")
            var jobs: [(Int64, URL?, XMPFields, DevelopSettingsRecord?)] = []
            var copies: [Int64] = []
            for id in ids {
                guard let detail = try Self.fetchDetail(db, assetID: id) else { continue }
                if detail.asset.virtualCopyOf != nil {
                    copies.append(id)
                    continue
                }
                let m = detail.metadata
                let fields = XMPFields(rating: m.rating, flag: m.flag, colorLabel: m.colorLabel,
                                       keywords: detail.keywords, title: m.title, caption: m.caption,
                                       notes: try Self.sidecarNotes(db, assetID: id))
                let versionID = try Self.masterVersionID(db, assetID: id, create: false)
                let record = try versionID.flatMap { try DevelopSettingsRecord.fetchOne(db, key: $0) }
                jobs.append((id, detail.fileURL, fields, record))
            }
            return (jobs, copies)
        }

        var result = XMPWriteResult()
        var written: [Int64] = []
        for (id, url, fields, saved) in jobs {
            guard let url else {
                result.offline += 1
                continue
            }
            do {
                let settings = try saved.map { try DevelopRecovery.settings($0.json) }
                let history = try saved.map { try HistoryRecovery.catalogHistory($0.historyJson, settingsJSON: $0.json) }
                try XMPSidecar.write(fields, toSidecar: XMPSidecar.sidecarURL(for: url),
                                     develop: settings, filename: url.lastPathComponent, history: history)
                // A save during the file write must stay dirty. Compare the entire snapshot.
                try writer.write { db in
                    guard let detail = try Self.fetchDetail(db, assetID: id) else { return }
                    let m = detail.metadata
                    let current = XMPFields(rating: m.rating, flag: m.flag, colorLabel: m.colorLabel,
                                            keywords: detail.keywords, title: m.title, caption: m.caption,
                                            notes: try Self.sidecarNotes(db, assetID: id))
                    let version = try Self.masterVersionID(db, assetID: id, create: false)
                    let record = try version.flatMap { try DevelopSettingsRecord.fetchOne(db, key: $0) }
                    if current == fields && record == saved {
                        try AssetMetadata.filter(key: id).updateAll(db, Column("xmpDirty").set(to: false))
                    }
                }
                written.append(id)
            } catch {
                result.failures.append(ImportFailure(url: url, reason: error.localizedDescription))
            }
        }
        result.written = written.count
        _ = try writer.write { db in
            try AssetMetadata.filter(keys: copies).updateAll(db, Column("xmpDirty").set(to: false))
        }
        return result
    }

    /// A photo's notes as the sidecar keeps them: oldest first, empty ones left out.
    static func sidecarNotes(_ db: Database, assetID: Int64) throws -> [NotesRecovery.Note] {
        try fetchNotes(db, assetID: assetID).reversed()
            .filter { !NoteText.cleaned($0.text).isEmpty }
            .map { NotesRecovery.Note($0) }
    }
}
