import Foundation
import ImageIO

/// The catalog fields that round-trip through XMP.
public struct XMPFields: Sendable, Hashable {
    public var rating: Int?
    public var flag: Flag?
    public var colorLabel: ColorLabel?
    public var keywords: [String] = []
    public var title: String?
    public var caption: String?

    public init(rating: Int? = nil, flag: Flag? = nil, colorLabel: ColorLabel? = nil,
                keywords: [String] = [], title: String? = nil, caption: String? = nil) {
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
        self.keywords = keywords
        self.title = title
        self.caption = caption
    }
}

/// Reads and writes XMP sidecars next to originals. Originals themselves are never modified.
///
/// Sidecars use the Adobe naming convention (IMG_0001.CR3 -> IMG_0001.xmp) so Lightroom and
/// Bridge read them. Writing merges into an existing sidecar, keeping tags other apps wrote.
public enum XMPSidecar {
    // Serialize read/merge/replace across metadata and Develop writers, including pairs.
    static let writeLock = NSRecursiveLock()

    public static func readDevelop(for original: URL) throws -> DevelopSettings? {
        let url = sidecarURL(for: original)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let metadata = CGImageMetadataCreateFromXMPData(data as CFData),
              let mutable = CGImageMetadataCreateMutableCopy(metadata) else {
            throw DevelopRecovery.RecoveryError.invalidSidecar
        }
        CGImageMetadataRegisterNamespaceForPrefix(mutable, atelierNamespace as CFString,
                                                  atelierPrefix as CFString, nil)
        guard let json = string(mutable, DevelopRecovery.path) else { return nil }
        let packet = try DevelopRecovery.packet(json)
        guard let settings = packet.files[original.lastPathComponent] else { return nil }
        return try DevelopRecovery.settings(settings)
    }

    public static let atelierNamespace = "http://ns.atelier.app/xmp/1.0/"
    public static let atelierPrefix = "atelier"

    public static func sidecarURL(for original: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: Reading

    public static func read(sidecar url: URL) -> XMPFields? {
        guard let data = try? Data(contentsOf: url),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        return fields(from: metadata)
    }

    public static func fields(from metadata: CGImageMetadata) -> XMPFields {
        var fields = XMPFields()
        if let rating = string(metadata, "xmp:Rating"), let value = Int(rating) {
            // Lightroom writes -1 for rejected photos.
            if value < 0 {
                fields.flag = .rejected
                fields.rating = 0
            } else {
                fields.rating = min(value, 5)
            }
        }
        if let label = string(metadata, "xmp:Label") {
            fields.colorLabel = ColorLabel.allCases.first { $0.rawValue.caseInsensitiveCompare(label) == .orderedSame }
        }
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString),
           let values = CGImageMetadataTagCopyValue(tag) as? [Any] {
            fields.keywords = values.compactMap(stringValue)
        }
        fields.title = altText(metadata, "dc:title")
        fields.caption = altText(metadata, "dc:description")
        // Paths need the prefix registered; do that on a copy since `metadata` may be immutable.
        if let mutable = CGImageMetadataCreateMutableCopy(metadata) {
            CGImageMetadataRegisterNamespaceForPrefix(mutable, atelierNamespace as CFString,
                                                      atelierPrefix as CFString, nil)
            if let flag = string(mutable, "atelier:Flag"), let value = Int(flag) {
                fields.flag = Flag(rawValue: value)
            }
        }
        return fields
    }

    // MARK: Writing

    public static func write(_ fields: XMPFields, toSidecar url: URL,
                             develop: DevelopSettings? = nil, filename: String? = nil) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let metadata: CGMutableImageMetadata
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = CGImageMetadataCreateFromXMPData(data as CFData),
                  let copy = CGImageMetadataCreateMutableCopy(existing) else {
                throw DevelopRecovery.RecoveryError.invalidSidecar
            }
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        CGImageMetadataRegisterNamespaceForPrefix(metadata, atelierNamespace as CFString,
                                                  atelierPrefix as CFString, nil)

        if let develop, let filename {
            var packet = try string(metadata, DevelopRecovery.path).map(DevelopRecovery.packet)
                ?? DevelopRecovery.Packet()
            // Do not downgrade an entry written by a newer app or replace damaged edits.
            if let existing = packet.files[filename] { _ = try DevelopRecovery.settings(existing) }
            packet.files[filename] = try develop.encoded()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            set(metadata, DevelopRecovery.path, String(decoding: try encoder.encode(packet), as: UTF8.self))
        }

        set(metadata, "xmp:Rating", fields.rating.map(String.init))
        set(metadata, "xmp:Label", fields.colorLabel?.rawValue)
        set(metadata, "atelier:Flag", fields.flag.map { String($0.rawValue) })

        if fields.keywords.isEmpty {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:subject" as CFString)
        } else if let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore,
                                                     kCGImageMetadataPrefixDublinCore,
                                                     "subject" as CFString, .arrayUnordered,
                                                     fields.keywords as CFArray) {
            CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag)
        }
        setAltText(metadata, name: "title", fields.title)
        setAltText(metadata, name: "description", fields.caption)

        guard let data = CGImageMetadataCreateXMPData(metadata, nil) as Data? else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Helpers

    private static func string(_ metadata: CGImageMetadata, _ path: String) -> String? {
        CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }

    private static func stringValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if CFGetTypeID(value as CFTypeRef) == CGImageMetadataTagGetTypeID() {
            return CGImageMetadataTagCopyValue(value as! CGImageMetadataTag) as? String
        }
        return nil
    }

    private static func set(_ metadata: CGMutableImageMetadata, _ path: String, _ value: String?) {
        if let value {
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
        } else {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
    }

    /// dc:title and dc:description are rdf:Alt language alternatives keyed by x-default.
    /// ImageIO has no public way to build one, so parse a tiny XMP packet and copy its tag over.
    private static func setAltText(_ metadata: CGMutableImageMetadata, name: String, _ value: String?) {
        let path = "dc:\(name)" as CFString
        CGImageMetadataRemoveTagWithPath(metadata, nil, path)
        guard let value else { return }
        let packet = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:\(name)><rdf:Alt>\
            <rdf:li xml:lang="x-default">\(xmlEscaped(value))</rdf:li></rdf:Alt></dc:\(name)>\
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """
        guard let parsed = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData),
              let tag = CGImageMetadataCopyTagWithPath(parsed, nil, path) else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
    }

    /// Reads a plain or language-alternative string.
    private static func altText(_ metadata: CGImageMetadata, _ path: String) -> String? {
        if let value = string(metadata, path) { return value }
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if let items = value as? [Any] { return items.lazy.compactMap(stringValue).first }
        if let dictionary = value as? [String: Any] {
            return (dictionary["x-default"] ?? dictionary.values.first).flatMap(stringValue)
        }
        return stringValue(value)
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
