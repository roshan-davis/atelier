import Foundation

/// What a Processor run is doing, for its progress line: Edit In, AI recipes and Generative Fill
/// report the same way.
public struct ProcessorProgress: Sendable, Equatable {
    public var phase: String
    /// How far the processor has got, 0...1, when it reports it (ComfyUI does).
    public var fraction: Double?

    public init(_ phase: String, fraction: Double? = nil) {
        self.phase = phase
        self.fraction = fraction
    }
}

/// A Processor's output: a new photo, catalogued and stacked on its source.
public struct ProcessorResult: Sendable, Equatable {
    public var assetID: Int64
    public var url: URL

    public init(assetID: Int64, url: URL) {
        self.assetID = assetID
        self.url = url
    }
}

/// The steps every Processor shares, the start of the one Processor contract (PRD "Processor",
/// AT-008, AT-076 D3): render the source photo as the processor's input, then catalog what it
/// made as a new photo stacked on the source, with how it was made. Edit In (an app that edits
/// the input interactively) and the AI recipes (a backend that returns a new image) both use it.
/// Recipes and headless plugins will plug in here too.
public struct ProcessorHost: Sendable {
    let catalog: Catalog
    let importer: Importer

    public init(catalog: Catalog, importer: Importer? = nil) {
        self.catalog = catalog
        self.importer = importer ?? Importer(catalog: catalog, previews: nil)
    }

    /// The source photo's original, or the error every processor shows when it's offline.
    public func original(of assetID: Int64) throws -> URL {
        guard let url = try catalog.fileURL(for: assetID), FileManager.default.fileExists(atPath: url.path) else {
            throw ProcessorError("The original is offline. Connect its drive and try again.")
        }
        return url
    }

    /// Renders the source photo as `settings` say (with or without its develop settings) and
    /// returns the file: the processor's input.
    public func renderInput(of assetID: Int64, settings: ExportSettings, baseName: String? = nil,
                            develop: Bool = true) throws -> URL {
        _ = try original(of: assetID)
        return try Exporter(catalog: catalog).export(assetID, settings: settings, baseName: baseName, develop: develop)
    }

    /// Catalogs `file` where it is and stacks it on the source photo as `kind`, named `name`,
    /// with `provenance` (JSON) recording how it was made.
    public func registerResult(_ file: URL, on assetID: Int64, kind: VersionKind, name: String?,
                               provenance: String? = nil) throws -> ProcessorResult {
        let id = try importer.addStacked(file, on: assetID, kind: kind, name: name, provenance: provenance)
        return ProcessorResult(assetID: id, url: file)
    }
}

public struct ProcessorError: LocalizedError, Sendable {
    let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
