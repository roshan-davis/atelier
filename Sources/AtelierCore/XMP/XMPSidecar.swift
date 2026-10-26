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
        fields.title = string(metadata, "dc:title")
        fields.caption = string(metadata, "dc:description")
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

    public static func write(_ fields: XMPFields, toSidecar url: URL) throws {
        let metadata: CGMutableImageMetadata
        if let data = try? Data(contentsOf: url),
           let existing = CGImageMetadataCreateFromXMPData(data as CFData),
           let copy = CGImageMetadataCreateMutableCopy(existing) {
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        CGImageMetadataRegisterNamespaceForPrefix(metadata, atelierNamespace as CFString,
                                                  atelierPrefix as CFString, nil)

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

    /// dc:title and dc:description are language alternatives keyed by x-default.
    private static func setAltText(_ metadata: CGMutableImageMetadata, name: String, _ value: String?) {
        let path = "dc:\(name)" as CFString
        guard let value else {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path)
            return
        }
        if let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore,
                                              kCGImageMetadataPrefixDublinCore,
                                              name as CFString, .alternateText,
                                              ["x-default": value] as CFDictionary) {
            CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
        }
    }
}
