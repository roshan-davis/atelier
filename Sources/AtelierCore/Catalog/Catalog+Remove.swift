import Foundation
import GRDB

/// Photo > Remove Photo…: takes photos out of the catalog, and with Delete from Disk also moves
/// their files to the Trash. Files are never erased here; a volume without a Trash (most network
/// shares) is reported back so the app can ask before deleting them for good.
public struct RemovalPlan: Sendable, Equatable {
    /// One file behind a photo being removed.
    public struct File: Sendable, Hashable {
        public var assetID: Int64
        public var filename: String
        /// nil while the file's drive or share isn't connected.
        public var url: URL?
        public var type: FileType
        /// Virtual copies of this photo, which leave the catalog with it.
        public var virtualCopyCount = 0
    }

    /// A kind of file in the plan, with a checkbox in the dialog when there is more than one.
    public struct FileType: Sendable, Hashable, Comparable, Identifiable {
        /// The extension in capitals, JPEG and TIFF spelled JPG and TIF: "NEF", "JPG".
        public var id: String
        public var isRaw: Bool

        init(filename: String) {
            let ext = (filename as NSString).pathExtension.uppercased()
            id = ["JPEG": "JPG", "TIFF": "TIF"][ext] ?? ext
            isRaw = FilePairs.isRaw(filename)
        }

        /// "RAW (.NEF)", "JPEG (.JPG)".
        public var label: String {
            if isRaw { return "RAW (.\(id))" }
            let name = ["JPG": "JPEG", "TIF": "TIFF"][id] ?? id
            return name == id ? ".\(id)" : "\(name) (.\(id))"
        }

        /// RAWs first, then by extension.
        public static func < (a: FileType, b: FileType) -> Bool {
            a.isRaw != b.isRaw ? a.isRaw : a.id < b.id
        }
    }

    /// The photos' own files (masters, Edit In and AI results, a RAW's paired JPEG).
    public var files: [File]
    /// Virtual copies picked for removal. They share another photo's file, so they only ever
    /// leave the catalog.
    public var virtualCopies: [Int64]

    /// The kinds of file, RAWs first.
    public var fileTypes: [FileType] {
        Set(files.map(\.type)).sorted()
    }

    public func files(of types: Set<FileType>) -> [File] {
        files.filter { types.contains($0.type) }
    }
}

/// What Delete from Disk did.
public struct DeletionResult: Sendable {
    /// Files moved to the Trash (their photos left the catalog).
    public var trashed: [RemovalPlan.File] = []
    /// Photos whose file was already gone, removed from the catalog only.
    public var missing: [RemovalPlan.File] = []
    /// Files on a drive or share that isn't connected; their photos stay.
    public var offline: [RemovalPlan.File] = []
    /// Files that couldn't go to the Trash (a share without one, or no permission); their
    /// photos stay. `reason` is the system's message.
    public var notTrashed: [(file: RemovalPlan.File, reason: String)] = []
}

extension Catalog {
    /// What removing these photos involves. Pass a RAW's paired files too (`withPairSiblings`)
    /// when pairs are shown as one photo.
    public func removalPlan(for assetIDs: [Int64]) throws -> RemovalPlan {
        try writer.read { db in
            var files: [RemovalPlan.File] = []
            var copies: [Int64] = []
            for id in assetIDs {
                guard let detail = try Self.fetchDetail(db, assetID: id) else { continue }
                if detail.asset.virtualCopyOf != nil {
                    copies.append(id)
                    continue
                }
                let copyCount = try Asset.filter(Column("virtualCopyOf") == id).fetchCount(db)
                files.append(RemovalPlan.File(assetID: id, filename: detail.asset.filename, url: detail.fileURL,
                                              type: RemovalPlan.FileType(filename: detail.asset.filename),
                                              virtualCopyCount: copyCount))
            }
            return RemovalPlan(files: files, virtualCopies: copies)
        }
    }

    /// Takes photos out of the catalog with their develop settings, metadata, collections, import
    /// entries and virtual copies. Their files stay where they are. An Edit In or AI result
    /// stacked on a removed photo stays, as a photo of its own.
    public func removePhotos(_ assetIDs: [Int64]) throws {
        guard !assetIDs.isEmpty else { return }
        try writer.write { db in
            try Asset.filter(keys: assetIDs).deleteAll(db)
            try db.execute(sql: "DELETE FROM cullGroup WHERE id NOT IN (SELECT cullGroupId FROM cullGroupAsset)")
        }
    }

    /// Delete from Disk: moves each file to the Trash, then removes its photo. A file that can't
    /// be trashed keeps its photo. XMP sidecars go to the Trash with the last photo of their name
    /// in the folder. `trash` stands in for `FileManager.trashItem` in tests.
    public func deletePhotos(_ files: [RemovalPlan.File], virtualCopies: [Int64] = [],
                             trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        throws -> DeletionResult {
        var result = DeletionResult()
        for file in files {
            guard let url = file.url else {
                result.offline.append(file)
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.missing.append(file)
                continue
            }
            do {
                try trash(url)
                result.trashed.append(file)
            } catch {
                result.notTrashed.append((file, error.localizedDescription))
            }
        }
        let gone = result.trashed + result.missing
        try removePhotos(gone.map(\.assetID) + virtualCopies)
        trashOrphanedSidecars(of: result.trashed, trash: trash)
        return result
    }

    /// Deletes files for good, for a share without a Trash once the person has said so.
    public func deletePhotosImmediately(_ files: [RemovalPlan.File]) throws -> DeletionResult {
        try deletePhotos(files) { try FileManager.default.removeItem(at: $0) }
    }

    /// A RAW and its JPEG share DSC_0001.xmp, so it goes only when neither is left in the catalog.
    private func trashOrphanedSidecars(of files: [RemovalPlan.File], trash: (URL) throws -> Void) {
        var seen: Set<URL> = []
        for file in files {
            guard let url = file.url else { continue }
            let sidecar = XMPSidecar.sidecarURL(for: url)
            guard seen.insert(sidecar).inserted, FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            let stem = FilePairs.stem(of: url.lastPathComponent)
            let folder = url.deletingLastPathComponent().standardizedFileURL.path
            let remaining = (try? writer.read { db in
                try Asset.filter(Column("stem") == stem).fetchAll(db).compactMap { asset in
                    try Self.fetchDetail(db, assetID: asset.id!)?.fileURL
                }
            }) ?? []
            if remaining.contains(where: { $0.deletingLastPathComponent().standardizedFileURL.path == folder }) { continue }
            try? trash(sidecar)
        }
    }
}
