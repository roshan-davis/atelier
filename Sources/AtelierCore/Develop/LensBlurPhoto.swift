import Foundation
import GRDB

/// Lens Blur's result (AT-074): the blurred photo, rendered at full size as a 16-bit ProPhoto
/// TIFF next to the original and stacked on it, as an Edit In copy is. Lens Blur is edited in
/// its own mode and renders nowhere else (`DevelopSession.rendersLensBlur`), so Develop's
/// sliders never re-run it; the TIFF is what the library, Develop and export see.
///
/// Saving again replaces the TIFF's pixels in place: the stack keeps one Lens Blur photo per
/// original, and the TIFF's own edits, rating and keywords stay. The settings the TIFF was made
/// from are kept on its version row, to tell when it no longer matches the original's.
public enum LensBlurPhoto {
    /// The version name that marks a stacked photo as the Lens Blur result.
    public static let versionName = "Lens Blur"

    public struct Saved: Sendable, Equatable {
        public var id: Int64
        public var url: URL
        /// The first save of this original: the photo was just added to the catalog.
        public var isNew: Bool
    }

    /// Renders `sourceID` with its develop settings and Lens Blur, and stacks the TIFF on it
    /// (or replaces the TIFF a previous save made). Runs off the main thread: a full-size render.
    public static func save(_ sourceID: Int64, catalog: Catalog, importer: Importer) throws -> Saved {
        guard let original = try catalog.fileURL(for: sourceID),
              FileManager.default.fileExists(atPath: original.path) else {
            throw ExportError("The original is offline. Connect its drive and save again.")
        }
        let madeFrom = try catalog.developSettings(for: sourceID)
        let recipe = String(data: try JSONEncoder().encode(madeFrom), encoding: .utf8)
        let existing = try version(of: sourceID, catalog: catalog)
        var existingFile: URL?
        if let id = existing?.derivedAssetId, let url = try catalog.fileURL(for: id),
           FileManager.default.fileExists(atPath: url.path) {
            existingFile = url
        }

        var settings = ExportSettings(destination: existingFile?.deletingLastPathComponent()
                                      ?? DerivedFiles.folder(for: original))
        settings.format = .tiff
        settings.colorSpace = .proPhoto
        settings.metadata = .all
        let base = original.deletingPathExtension().lastPathComponent + "-LensBlur"
        let file = try Exporter(catalog: catalog).export(sourceID, settings: settings, baseName: base,
                                                         develop: true, lensBlur: true)

        if let existing, let id = existing.derivedAssetId, let existingFile {
            // Written beside it under a new name first, so a failed render never leaves half a file.
            _ = try FileManager.default.replaceItemAt(existingFile, withItemAt: file)
            try catalog.refreshFileInfo(for: id)
            try setRecipe(recipe, of: id, catalog: catalog)
            return Saved(id: id, url: existingFile, isNew: false)
        }
        let id = try importer.addStacked(file, on: sourceID, kind: .externalEdit, name: versionName,
                                         provenance: recipe)
        return Saved(id: id, url: file, isNew: true)
    }

    /// The Lens Blur photo stacked on `sourceID`, if one was saved.
    public static func version(of sourceID: Int64, catalog: Catalog) throws -> PhotoVersion? {
        try catalog.writer.read { db in
            try PhotoVersion
                .filter(Column("assetId") == sourceID && Column("name") == versionName && Column("derivedAssetId") != nil)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    /// The original a Lens Blur photo was made from, when `assetID` is one.
    public static func source(of assetID: Int64, catalog: Catalog) throws -> Int64? {
        guard let derivation = try catalog.derivation(of: assetID), derivation.name == versionName else { return nil }
        return derivation.assetId
    }

    /// The original's settings the Lens Blur photo was last saved from.
    public static func madeFrom(_ version: PhotoVersion) -> DevelopSettings? {
        guard let data = version.provenance?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DevelopSettings.self, from: data)
    }

    private static func setRecipe(_ recipe: String?, of derivedID: Int64, catalog: Catalog) throws {
        try catalog.writer.write { db in
            try db.execute(sql: "UPDATE version SET provenance = ? WHERE derivedAssetId = ?",
                           arguments: [recipe, derivedID])
        }
    }
}
