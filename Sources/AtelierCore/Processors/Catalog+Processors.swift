import Foundation
import GRDB

public struct ProcessorAssociation: Sendable {
    public var projectURL: URL
    public var projectID: UUID
    public var outputID: UUID
    public var sourceAssetID: Int64
    public var sourceHash: String
    public var revision: Int
}

extension Catalog {
    static func registerProcessorMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8-processor-documents") { db in
            try db.create(table: "processorOutput") { t in
                t.column("outputID", .text).primaryKey()
                t.column("projectID", .text).notNull()
                t.column("projectPath", .text).notNull()
                t.column("sourceAssetID", .integer).notNull().references("asset", onDelete: .cascade)
                t.column("derivedAssetID", .integer).notNull().unique().references("asset", onDelete: .cascade)
                t.column("sourceHash", .text).notNull()
                t.column("revision", .integer).notNull()
                t.column("resultHash", .text).notNull()
            }
            try db.create(table: "processorCompletion") { t in
                t.column("jobID", .text).notNull()
                t.column("outputID", .text).notNull()
                t.column("revision", .integer).notNull()
                t.column("resultHash", .text).notNull()
                t.column("derivedAssetID", .integer).notNull().references("asset", onDelete: .cascade)
                t.primaryKey(["jobID", "outputID", "revision"])
            }
        }
    }

    public func processorAssociation(for assetID: Int64) throws -> ProcessorAssociation? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM processorOutput WHERE derivedAssetID = ?", arguments: [assetID]),
                  let projectID = UUID(uuidString: row["projectID"]), let outputID = UUID(uuidString: row["outputID"]) else { return nil }
            return ProcessorAssociation(projectURL: URL(fileURLWithPath: row["projectPath"]), projectID: projectID,
                                        outputID: outputID, sourceAssetID: row["sourceAssetID"],
                                        sourceHash: row["sourceHash"], revision: row["revision"])
        }
    }

    public func hasConsumedProcessorResult(_ receipt: ProcessorReceipt, request: ProcessorDocument) throws -> Bool {
        try receipt.validateIdentity(against: request)
        return try consumedProcessorAsset(receipt, request: request) != nil
    }

    private func consumedProcessorAsset(_ receipt: ProcessorReceipt, request: ProcessorDocument) throws -> Int64? {
        try writer.read { db in
            if let id = try Int64.fetchOne(db, sql: "SELECT derivedAssetID FROM processorCompletion WHERE jobID = ? AND outputID = ? AND revision = ? AND resultHash = ?",
                arguments: [receipt.jobID.uuidString, receipt.outputID.uuidString, receipt.revision, receipt.resultHash]) { return id }
            return try Int64.fetchOne(db, sql: """
                SELECT derivedAssetID FROM processorOutput
                WHERE outputID = ? AND projectID = ? AND projectPath = ? AND sourceAssetID = ?
                    AND sourceHash = ? AND revision = ? AND resultHash = ?
                """, arguments: [receipt.outputID.uuidString, receipt.projectID.uuidString, request.projectURL.path,
                                  request.sourceAssetID, request.sourceHash, receipt.revision, receipt.resultHash])
        }
    }

    /// Validate first, then import, link and consume revision in the same database transaction.
    /// Replays update the same output; a stale completion cannot replace a newer catalog revision.
    public func acceptProcessorResult(_ receipt: ProcessorReceipt, request: ProcessorDocument) throws -> Int64 {
        try receipt.validateIdentity(against: request)
        if let consumed = try consumedProcessorAsset(receipt, request: request) { return consumed }
        try receipt.validate(against: request)
        let provenance = String(data: try JSONEncoder().encode(request), encoding: .utf8)
        let values = try request.resultURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let outcome = try Importer(catalog: self, previews: nil).importFile(request.resultURL,
            options: ImportOptions(buildPreviews: false), registration: { db, derivedID in
                if let existing = try Row.fetchOne(db, sql: "SELECT * FROM processorOutput WHERE outputID = ?", arguments: [receipt.outputID.uuidString]) {
                    let oldRevision: Int = existing["revision"]
                    let oldHash: String = existing["resultHash"]
                    let oldAsset: Int64 = existing["derivedAssetID"]
                    guard oldAsset == derivedID, oldRevision <= receipt.revision,
                          oldRevision != receipt.revision || oldHash == receipt.resultHash else { throw ProcessorDocumentError.staleRevision }
                } else {
                    guard try Asset.fetchOne(db, key: request.sourceAssetID) != nil else { throw ProcessorDocumentError.invalidRequest }
                    var version = PhotoVersion(assetId: request.sourceAssetID, kind: .externalEdit,
                                               name: "Lightfast HDR", filePath: request.resultURL.path,
                                               derivedAssetId: derivedID, provenance: provenance)
                    try version.insert(db)
                    try Self.copyCatalogInfo(db, from: request.sourceAssetID, to: derivedID)
                }
                try db.execute(sql: """
                    INSERT INTO processorOutput (outputID, projectID, projectPath, sourceAssetID, derivedAssetID, sourceHash, revision, resultHash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(outputID) DO UPDATE SET revision = excluded.revision, resultHash = excluded.resultHash
                    """, arguments: [receipt.outputID.uuidString, receipt.projectID.uuidString, request.projectURL.path,
                                      request.sourceAssetID, derivedID, request.sourceHash, receipt.revision, receipt.resultHash])
                try db.execute(sql: "INSERT OR IGNORE INTO processorCompletion (jobID, outputID, revision, resultHash, derivedAssetID) VALUES (?, ?, ?, ?, ?)",
                               arguments: [receipt.jobID.uuidString, receipt.outputID.uuidString, receipt.revision, receipt.resultHash, derivedID])
                try db.execute(sql: "UPDATE asset SET fileSize = ?, modifiedAt = ?, contentHash = ?, width = ?, height = ? WHERE id = ?",
                               arguments: [values.fileSize, values.contentModificationDate, receipt.resultHash, receipt.width, receipt.height, derivedID])
            })
        switch outcome {
        case .imported(let id, _, _), .existing(let id): return id
        }
    }
}
