import Foundation

/// Photo notes in XMP sidecars (AT-058): only in Atelier's own `atelier:Notes` field, never in
/// Caption (`dc:description`), IPTC Instructions or EXIF User Comment, so other apps and exports
/// never see or overwrite them. Like `DevelopRecovery`, a format-version-1 JSON packet keyed by
/// exact filename, because a sidecar is shared by same-stem RAW and JPEG originals.
public enum NotesRecovery {
    static let path = "atelier:Notes"

    /// One note as the sidecar keeps it.
    public struct Note: Codable, Hashable, Sendable {
        public var text: String
        public var source: NoteSource
        public var app: String?
        public var created: Date
        public var edited: Date?

        public init(text: String, source: NoteSource, app: String? = nil, created: Date, edited: Date? = nil) {
            self.text = text
            self.source = source
            self.app = app
            self.created = created
            self.edited = edited
        }

        public init(_ note: PhotoNote) {
            self.init(text: note.text, source: note.source, app: note.appName, created: note.createdAt,
                      edited: note.editedAt)
        }

        /// The catalog record for `assetID`.
        public func record(assetID: Int64) -> PhotoNote {
            PhotoNote(assetId: assetID, text: text, source: source, appName: app, createdAt: created, editedAt: edited)
        }
    }

    struct Packet: Codable {
        var formatVersion = 1
        var files: [String: [Note]] = [:]
    }

    static func packet(_ json: String) throws -> Packet {
        let packet = try decoder.decode(Packet.self, from: Data(json.utf8))
        guard packet.formatVersion == 1 else { throw DevelopRecovery.RecoveryError.unsupported }
        return packet
    }

    static func json(_ packet: Packet) throws -> String {
        String(decoding: try encoder.encode(packet), as: UTF8.self)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
