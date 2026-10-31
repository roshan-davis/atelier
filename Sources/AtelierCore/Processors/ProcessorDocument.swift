import Foundation
import ImageIO

/// Focused interactive extension of the Processor boundary. App-specific settings stay in
/// the processor project; the catalog owns request/result identity and source relationships.
public struct ProcessorDocument: Codable, Equatable, Sendable {
    public var protocolVersion = 1
    public var jobID: UUID
    public var processorID: String
    public var uiPreferences: [String: String]?
    public var hostProcessID: Int32?
    public var hostBundleURL: URL?
    public var sourceAssetID: Int64
    public var sourceURL: URL
    public var sourceHash: String
    public var projectURL: URL
    public var expectedProjectID: UUID?
    public var outputID: UUID?
    public init(sourceAssetID: Int64, sourceURL: URL, sourceHash: String, projectURL: URL,
                expectedProjectID: UUID? = nil, outputID: UUID? = nil) {
        jobID = UUID(); processorID = "atelier.hdr"
        hostProcessID = ProcessInfo.processInfo.processIdentifier; hostBundleURL = Bundle.main.bundleURL
        self.sourceAssetID = sourceAssetID; self.sourceURL = sourceURL
        self.sourceHash = sourceHash; self.projectURL = projectURL
        self.expectedProjectID = expectedProjectID; self.outputID = outputID
    }
    public var resultURL: URL { projectURL.deletingPathExtension().appendingPathExtension("tif") }
    public func write(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
    public static func read(_ url: URL) throws -> Self {
        let request = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard request.protocolVersion == 1, request.processorID == "atelier.hdr",
              request.sourceURL.isFileURL, request.projectURL.isFileURL,
              request.projectURL.pathExtension == "atelierhdr" else { throw ProcessorDocumentError.invalidRequest }
        return request
    }
}

public struct ProcessorReceipt: Codable, Sendable {
    public var protocolVersion = 1
    public var jobID: UUID
    public var projectID: UUID
    public var outputID: UUID
    public var revision: Int
    public var sourceHash: String
    public var resultHash: String
    public var generationID: UUID
    public var width: Int
    public var height: Int
    public init(jobID: UUID, projectID: UUID, outputID: UUID, revision: Int, sourceHash: String,
                resultHash: String, generationID: UUID, width: Int, height: Int) {
        self.jobID = jobID; self.projectID = projectID; self.outputID = outputID
        self.revision = revision; self.sourceHash = sourceHash; self.resultHash = resultHash
        self.generationID = generationID; self.width = width; self.height = height
    }
    public func write(to url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
    public static func read(_ url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func validateIdentity(against request: ProcessorDocument) throws {
        guard protocolVersion == 1, jobID == request.jobID, revision > 0,
              sourceHash == request.sourceHash, width > 0, height > 0,
              request.expectedProjectID == nil || request.expectedProjectID == projectID,
              request.outputID == nil || request.outputID == outputID else { throw ProcessorDocumentError.invalidReceipt }
    }
    public func validate(against request: ProcessorDocument) throws {
        try validateIdentity(against: request)
        let result = request.resultURL
        let values = try result.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              try FileHasher.sha256(of: result) == resultHash,
              let source = CGImageSourceCreateWithURL(result as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height, image.bitsPerComponent == 16,
              image.colorSpace?.copyICCData() != nil else { throw ProcessorDocumentError.invalidReceipt }
        let generationFolder = request.projectURL.appendingPathComponent("Generations").appendingPathComponent(generationID.uuidString)
        let manifestURL = generationFolder.appendingPathComponent("manifest.json")
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              manifest["schemaVersion"] as? Int == 1,
              manifest["projectID"] as? String == projectID.uuidString,
              manifest["outputID"] as? String == outputID.uuidString,
              manifest["generationID"] as? String == generationID.uuidString,
              manifest["revision"] as? Int == revision,
              manifest["sourceHash"] as? String == sourceHash,
              manifest["resultHash"] as? String == resultHash,
              manifest["width"] as? Int == width, manifest["height"] as? Int == height else {
            throw ProcessorDocumentError.invalidReceipt
        }
        let generation = request.projectURL.appendingPathComponent("Generations")
            .appendingPathComponent(generationID.uuidString).appendingPathComponent("result.tif")
        guard try FileHasher.sha256(of: generation) == resultHash else { throw ProcessorDocumentError.invalidReceipt }
    }
}

public enum ProcessorDocumentError: Error, LocalizedError {
    case invalidRequest, invalidReceipt, staleRevision
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The processor request is invalid or unsupported."
        case .invalidReceipt: return "The processor result does not match its saved request."
        case .staleRevision: return "A newer processor result is already cataloged."
        }
    }
}
