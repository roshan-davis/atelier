import Foundation
import GRDB

/// RAW+JPEG pairs: a camera that writes DSC_0001.NEF and DSC_0001.JPG (or HEIC, TIFF) shot one
/// picture. Every file is cataloged as its own photo, and while pairs are grouped (Settings >
/// Import, on by default) only the RAW is shown, carrying a "RAW+JPG" badge. Its siblings
/// follow it: ratings, flags, labels, keywords, collections and import entries set on the RAW
/// are set on them too. Develop settings and exports use the RAW alone.
public enum FilePairs {
    /// The UserDefaults key for Settings > Import > "Show RAW+JPEG pairs as one photo".
    public static let groupKey = "library.groupRawPairs"
    /// Posted when Settings turns grouping on or off, so the Library can refilter.
    public static let groupingChanged = Notification.Name("AtelierRawPairGroupingChanged")

    /// Whether pairs are grouped; on unless turned off in Settings.
    public static var isGrouping: Bool {
        UserDefaults.standard.object(forKey: groupKey) as? Bool ?? true
    }

    static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "gpr", "iiq", "k25", "kdc",
        "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
    ]

    public static func isRaw(_ filename: String) -> Bool {
        rawExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    public static func stem(of filename: String) -> String {
        (filename as NSString).deletingPathExtension.lowercased()
    }

    /// Files in one folder that share a name: the RAW to show and the files that go with it.
    /// A name with no RAW, or with two RAWs, isn't a pair; those files stand alone.
    public static func pairs(_ files: [URL]) -> [(primary: URL, siblings: [URL])] {
        var byName: [String: [URL]] = [:]
        var order: [String] = []
        for file in files {
            let key = file.deletingLastPathComponent().path + "/" + stem(of: file.lastPathComponent)
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(file)
        }
        var result: [(URL, [URL])] = []
        for key in order {
            let group = byName[key]!
            let raws = group.filter { isRaw($0.lastPathComponent) }
            if raws.count == 1 {
                result.append((raws[0], group.filter { $0 != raws[0] }))
            } else {
                result.append(contentsOf: group.map { ($0, []) })
            }
        }
        return result
    }

    /// SQL that is true for a photo hidden behind its RAW. `asset` names the photo's table alias;
    /// stacked Edit In and AI results and virtual copies are never hidden.
    static func hiddenCondition(_ asset: String = "asset") -> String {
        """
        (\(asset).isRaw = 0 AND \(asset).virtualCopyOf IS NULL
         AND NOT EXISTS (SELECT 1 FROM version WHERE version.derivedAssetId = \(asset).id)
         AND (SELECT COUNT(*) FROM asset pairRaw WHERE pairRaw.folderId = \(asset).folderId
              AND pairRaw.stem = \(asset).stem AND pairRaw.isRaw = 1 AND pairRaw.virtualCopyOf IS NULL) = 1)
        """
    }
}

extension Catalog {
    static func registerPairMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7-raw-pairs") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "stem", .text)
                t.add(column: "isRaw", .boolean).notNull().defaults(to: false)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, filename FROM asset")
            for row in rows {
                let filename: String = row["filename"]
                try db.execute(sql: "UPDATE asset SET stem = ?, isRaw = ? WHERE id = ?",
                               arguments: [FilePairs.stem(of: filename), FilePairs.isRaw(filename), row["id"] as Int64])
            }
            try db.create(index: "asset_on_folderId_stem", on: "asset", columns: ["folderId", "stem"])
        }
    }

    /// The files hidden behind each of these RAWs. Photos that aren't a pair's RAW have none.
    static func pairSiblings(_ db: Database, of assetIDs: [Int64]) throws -> [Int64] {
        guard !assetIDs.isEmpty else { return [] }
        let list = assetIDs.map(String.init).joined(separator: ",")
        return try Int64.fetchAll(db, sql: """
            SELECT sibling.id FROM asset raw
            JOIN asset sibling ON sibling.folderId = raw.folderId AND sibling.stem = raw.stem AND sibling.id != raw.id
            WHERE raw.id IN (\(list)) AND raw.isRaw = 1 AND raw.virtualCopyOf IS NULL
              AND \(FilePairs.hiddenCondition("sibling"))
            """)
    }

    public func pairSiblings(of assetIDs: [Int64]) throws -> [Int64] {
        try writer.read { db in try Self.pairSiblings(db, of: assetIDs) }
    }

    /// The photos plus the files hidden behind them, for edits that apply to a whole pair.
    public func withPairSiblings(_ assetIDs: [Int64]) throws -> [Int64] {
        let siblings = try pairSiblings(of: assetIDs)
        return assetIDs + siblings.filter { !assetIDs.contains($0) }
    }
}
