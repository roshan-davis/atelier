import Foundation
import CryptoKit
import Darwin

public struct HDRProjectManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var projectID: UUID
    public var sourceName: String
    public var sourceHash: String
    public var settings: HDRSettings
    public var outputID: UUID
    public var generationID: UUID?
    public var revision: Int = 0
    public var width: Int = 0
    public var height: Int = 0
    public var resultHash: String?
    public var engineVersion: String = "1"
    public var decoderOS: String = ProcessInfo.processInfo.operatingSystemVersionString
}

/// One writer per project. Originals are read-only and source copies are byte verified.
/// Immutable generation manifests are committed before the current pointer. The public TIFF
/// is recoverable from that generation; it is not one transaction with the project or catalog.
public actor HDRProjectStore {
    public let url: URL
    public private(set) var manifest: HDRProjectManifest

    private init(url: URL, manifest: HDRProjectManifest) { self.url = url; self.manifest = manifest }

    public static func create(at url: URL, source: URL) throws -> HDRProjectStore {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path),
              !fm.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("tif").path) else { throw HDRError.invalidProject("The destination already exists.") }
        let sourceHash = try hash(source)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try fm.createDirectory(at: url.appendingPathComponent("Sources"), withIntermediateDirectories: false)
            try fm.createDirectory(at: url.appendingPathComponent("Generations"), withIntermediateDirectories: false)
            let sourceName = "source." + source.pathExtension.lowercased()
            let copy = url.appendingPathComponent("Sources").appendingPathComponent(sourceName)
            try fm.copyItem(at: source, to: copy)
            guard try hash(copy) == sourceHash, try hash(source) == sourceHash else {
                throw HDRError.invalidProject("The source changed while copying.")
            }
            let manifest = HDRProjectManifest(projectID: UUID(), sourceName: sourceName,
                                               sourceHash: sourceHash, settings: HDRSettings(), outputID: UUID())
            try write(manifest, to: url.appendingPathComponent("project.json"))
            return HDRProjectStore(url: url, manifest: manifest)
        } catch {
            // Preserve partial preparation for diagnosis; never remove caller source files.
            throw error
        }
    }

    public static func open(_ url: URL) throws -> HDRProjectStore {
        let manifest = try JSONDecoder().decode(HDRProjectManifest.self, from: Data(contentsOf: url.appendingPathComponent("project.json")))
        guard manifest.schemaVersion == 1, manifest.engineVersion == "1",
              manifest.sourceName == "source." + URL(fileURLWithPath: manifest.sourceName).pathExtension,
              !manifest.sourceName.contains("/"), !manifest.sourceName.contains("\\"), manifest.revision >= 0 else {
            throw HDRError.invalidProject("Unsupported or invalid manifest.")
        }
        try manifest.settings.validate()
        let source = url.appendingPathComponent("Sources").appendingPathComponent(manifest.sourceName)
        try regularFile(source)
        guard try hash(source) == manifest.sourceHash else {
            throw HDRError.invalidProject("The owned source is missing or changed. Restore the verified source copy.")
        }
        if let generation = manifest.generationID {
            let folder = url.appendingPathComponent("Generations").appendingPathComponent(generation.uuidString)
            let saved = try JSONDecoder().decode(HDRProjectManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            guard saved == manifest, let expected = manifest.resultHash,
                  try hash(folder.appendingPathComponent("result.tif")) == expected else {
                throw HDRError.invalidProject("The committed generation is inconsistent.")
            }
            try HDRImageIO.validateTIFF(folder.appendingPathComponent("result.tif"), width: manifest.width, height: manifest.height)
        }
        return HDRProjectStore(url: url, manifest: manifest)
    }

    /// Explicit relink accepts only a byte-identical replacement; originals remain read-only.
    public static func relink(_ projectURL: URL, from replacement: URL) throws {
        let manifest = try JSONDecoder().decode(HDRProjectManifest.self, from: Data(contentsOf: projectURL.appendingPathComponent("project.json")))
        guard manifest.schemaVersion == 1, !manifest.sourceName.contains("/"),
              !manifest.sourceName.contains("\\"), manifest.sourceName.hasPrefix("source."),
              try hash(replacement) == manifest.sourceHash else {
            throw HDRError.invalidProject("The selected file does not match the saved source hash.")
        }
        let sources = projectURL.appendingPathComponent("Sources")
        let values = try sources.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HDRError.invalidProject("The owned Sources folder is unavailable.")
        }
        let staging = sources.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: replacement, to: staging)
        guard try hash(staging) == manifest.sourceHash else { throw HDRError.invalidProject("Replacement copy verification failed.") }
        let destination = sources.appendingPathComponent(manifest.sourceName)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Retain the damaged owned copy for recovery rather than deleting it.
            try FileManager.default.moveItem(at: destination, to: sources.appendingPathComponent("damaged-" + UUID().uuidString))
        }
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    public func sourceURL() -> URL { url.appendingPathComponent("Sources").appendingPathComponent(manifest.sourceName) }
    public func resultURL() -> URL { url.deletingPathExtension().appendingPathExtension("tif") }

    /// Renders full resolution from the owned source; cancellation leaves the last commit intact.
    @discardableResult
    public func save(settings: HDRSettings, cancellation: () throws -> Void = {}) throws -> HDRProjectManifest {
        try settings.validate(); try cancellation()
        let descriptor = Darwin.open(url.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HDRError.invalidProject("The project writer lock is unavailable.") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw HDRError.invalidProject("Another HDR window is saving this project. Try again when it finishes.")
        }
        let current = try JSONDecoder().decode(HDRProjectManifest.self, from: Data(contentsOf: url.appendingPathComponent("project.json")))
        guard current == manifest else {
            throw HDRError.invalidProject("Another window saved a newer revision. Reopen the project before editing further.")
        }
        let source = sourceURL()
        guard try Self.hash(source) == manifest.sourceHash else { throw HDRError.invalidProject("The source changed.") }
        let io = HDRImageIO()
        let input = try io.decode(source)
        try cancellation()
        let rendered = try HDRToneMapper.render(input, settings: settings, cancellation: cancellation)
        let generationID = UUID()
        let folder = url.appendingPathComponent("Generations").appendingPathComponent(generationID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let result = folder.appendingPathComponent("result.tif")
        try io.writeTIFF(rendered, to: result)
        try cancellation()
        var next = manifest
        next.generationID = generationID; next.revision += 1; next.settings = settings
        next.width = rendered.width; next.height = rendered.height; next.resultHash = try Self.hash(result)
        try Self.write(next, to: folder.appendingPathComponent("manifest.json"))
        try Self.write(next, to: url.appendingPathComponent("project.json"))
        manifest = next
        try publish()
        return next
    }

    /// Reconciles an interrupted public-file publication from the committed generation.
    public func publish() throws {
        guard let generation = manifest.generationID, let expected = manifest.resultHash else { return }
        let result = url.appendingPathComponent("Generations").appendingPathComponent(generation.uuidString).appendingPathComponent("result.tif")
        guard try Self.hash(result) == expected else { throw HDRError.invalidProject("The saved result changed.") }
        let destination = resultURL()
        if (try? Self.hash(destination)) == expected { return }
        let staging = url.deletingLastPathComponent().appendingPathComponent("publish-\(UUID().uuidString).tif")
        try FileManager.default.copyItem(at: result, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
    }

    /// Save As New forks a durable project and output identity, preserving the old project.
    public func fork(to destination: URL) throws -> HDRProjectStore {
        try Self.create(at: destination, source: sourceURL())
    }

    public static func hash(_ url: URL) throws -> String {
        try regularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func regularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HDRError.invalidProject("A required file is missing or is a symbolic link.")
        }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
