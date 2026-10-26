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
        let jobs: [(Int64, URL?, XMPFields)] = try writer.read { db in
            let ids = try assetIDs ?? Int64.fetchAll(db, sql: "SELECT assetId FROM metadata WHERE xmpDirty = 1")
            return try ids.compactMap { id in
                guard let detail = try Self.fetchDetail(db, assetID: id) else { return nil }
                let m = detail.metadata
                let fields = XMPFields(rating: m.rating, flag: m.flag, colorLabel: m.colorLabel,
                                       keywords: detail.keywords, title: m.title, caption: m.caption)
                return (id, detail.fileURL, fields)
            }
        }

        var result = XMPWriteResult()
        var written: [Int64] = []
        for (id, url, fields) in jobs {
            guard let url else {
                result.offline += 1
                continue
            }
            do {
                try XMPSidecar.write(fields, toSidecar: XMPSidecar.sidecarURL(for: url))
                written.append(id)
            } catch {
                result.failures.append(ImportFailure(url: url, reason: error.localizedDescription))
            }
        }
        result.written = written.count
        try writer.write { db in
            try AssetMetadata.filter(keys: written).updateAll(db, Column("xmpDirty").set(to: false))
        }
        return result
    }
}
