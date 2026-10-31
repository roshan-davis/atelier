import Foundation
import GRDB

// Records mirror the PRD data model (Volume, Folder, Asset, Metadata, Keyword, Collection).
// Version, DevelopSettings, Mask, Processor, Model and Job arrive with Phases 2 and 3.

public enum VolumeKind: String, Codable, Sendable, DatabaseValueConvertible {
    case local
    case nas
}

public struct Volume: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "volume"

    public var id: Int64?
    /// Stable identity: "uuid:<volume UUID>", or "net:<remount URL>" for SMB/AFP shares without a UUID.
    public var identityKey: String
    public var name: String
    public var kind: VolumeKind
    /// Where the volume was last mounted. Only meaningful while `isOnline`.
    public var mountPath: String?
    public var lastSeen: Date?
    public var isOnline: Bool

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Folder: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folder"

    public var id: Int64?
    public var volumeId: Int64
    /// Path relative to the volume root, without leading or trailing slash. Empty for the root.
    public var relativePath: String

    public var displayName: String {
        relativePath.isEmpty ? "/" : relativePath
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Asset: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "asset"

    public var id: Int64?
    public var folderId: Int64
    public var filename: String
    public var fileSize: Int64
    public var modifiedAt: Date?
    /// SHA-256 of the file contents, hex encoded.
    public var contentHash: String
    public var perceptualHash: String?
    public var captureTime: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var width: Int?
    public var height: Int?
    public var orientation: Int?
    public var uti: String?
    public var importedAt: Date
    /// Set on a virtual copy: the master photo whose file it shares.
    public var virtualCopyOf: Int64? = nil
    /// The filename without its extension, lowercased: how a RAW finds the JPEG shot with it.
    public var stem: String? = nil
    /// A camera RAW file (NEF, CR3, ARW, DNG…).
    public var isRaw: Bool = false

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum Flag: Int, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case rejected = -1
    case none = 0
    case picked = 1
}

public enum ColorLabel: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
}

public struct AssetMetadata: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "metadata"

    public var assetId: Int64
    public var rating: Int
    public var flag: Flag
    public var colorLabel: ColorLabel?
    public var title: String?
    public var caption: String?
    public var latitude: Double?
    public var longitude: Double?
    /// True when catalog values changed since the XMP sidecar was last written.
    public var xmpDirty: Bool

    public init(assetId: Int64, rating: Int = 0, flag: Flag = .none, colorLabel: ColorLabel? = nil,
                title: String? = nil, caption: String? = nil, latitude: Double? = nil,
                longitude: Double? = nil, xmpDirty: Bool = false) {
        self.assetId = assetId
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
        self.title = title
        self.caption = caption
        self.latitude = latitude
        self.longitude = longitude
        self.xmpDirty = xmpDirty
    }
}

public struct Keyword: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "keyword"

    public var id: Int64?
    public var name: String
    public var parentId: Int64?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct AssetKeyword: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "assetKeyword"
    public var assetId: Int64
    public var keywordId: Int64
}

/// Named `PhotoCollection` to avoid clashing with Swift's `Collection`.
public struct PhotoCollection: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "collection"

    public var id: Int64?
    public var name: String
    public var parentId: Int64?
    /// Collection sets group collections and hold no photos themselves.
    public var isSet: Bool
    /// Its photos are hidden everywhere until View > Show Private Photos (see `Catalog+Private`).
    public var isPrivate: Bool

    public init(id: Int64? = nil, name: String, parentId: Int64? = nil, isSet: Bool = false, isPrivate: Bool = false) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.isSet = isSet
        self.isPrivate = isPrivate
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct CollectionAsset: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collectionAsset"
    public var collectionId: Int64
    public var assetId: Int64
}

/// A named set of photos created by an import. More photos can be imported into it later,
/// and photos can be added or removed by hand. Removing a photo from an import, or deleting
/// the import, never removes the photo from the catalog.
public struct ImportGroup: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "importGroup"

    public var id: Int64?
    public var name: String
    public var createdAt: Date
    /// Its photos are hidden everywhere until View > Show Private Photos (see `Catalog+Private`).
    public var isPrivate: Bool

    public init(id: Int64? = nil, name: String, createdAt: Date = Date(), isPrivate: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isPrivate = isPrivate
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ImportGroupAsset: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "importGroupAsset"
    public var importGroupId: Int64
    public var assetId: Int64
}

/// An import entry for the sidebar, with its photo count and latest activity.
public struct ImportGroupSummary: Codable, Hashable, Identifiable, Sendable, FetchableRecord {
    public var id: Int64
    public var name: String
    public var createdAt: Date
    public var photoCount: Int
    public var isPrivate: Bool
}

/// One grid cell's worth of data, fetched in a single query.
public struct AssetRow: Codable, Hashable, Identifiable, Sendable, FetchableRecord {
    public var id: Int64
    public var filename: String
    public var captureTime: Date?
    public var folderId: Int64
    public var rating: Int
    public var flag: Flag
    public var colorLabel: ColorLabel?
    /// Set on an Edit In or AI result: the photo it is stacked on, and how it was made.
    public var stackParentId: Int64?
    public var stackKind: VersionKind?
    /// The version's name, such as "Copy 2" for a virtual copy.
    public var stackName: String?
    /// How many edits and AI results are stacked on this photo.
    public var stackCount: Int?
    /// How many photos were culled together with this one; nil when it was never in a cull group.
    public var cullGroupSize: Int?
    /// On a RAW shown for a RAW+JPEG pair: the other files' extensions, such as "JPG" or
    /// "JPG,HEIC". Nil when the photo has no hidden siblings.
    public var pairedFormats: String? = nil
    /// The thumbnail's status badges: Develop settings changed, cropped or straightened, local
    /// masks, and the original's drive offline.
    public var hasEdits = false
    public var isCropped = false
    public var hasMasks = false
    public var isOffline = false
}

/// Everything the inspector and loupe need for one photo.
public struct AssetDetail: Sendable, Hashable {
    public var asset: Asset
    public var metadata: AssetMetadata
    public var keywords: [String]
    public var folder: Folder
    public var volume: Volume
    /// Nil while the volume is offline.
    public var fileURL: URL?
}
