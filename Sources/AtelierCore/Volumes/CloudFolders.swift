import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Cloud drive folders (AT-079b): the folders the provider's own Mac app keeps in sync, under
/// `~/Library/CloudStorage` (Dropbox, Google Drive, OneDrive, Box, Synology Drive, …) and iCloud
/// Drive's `~/Library/Mobile Documents/com~apple~CloudDocs`. Each provider folder is its own volume
/// for the catalog: its identity is the provider folder's name, not where the Mac keeps it, so a new
/// sign-in to the same account or a new Mac relinks the photos. Atelier signs in to nothing: the
/// provider's app does the syncing, and Atelier only reads files (PRD "Storage locations").
public enum CloudFolders {
    static let iCloudKey = "cloud:iCloudDrive"

    /// The provider folders on this Mac, as volumes. `home` is for tests.
    public static func providers(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [MountedVolume] {
        var found: [MountedVolume] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if isDirectory(iCloud) {
            found.append(MountedVolume(identityKey: iCloudKey, name: "iCloud Drive", kind: .cloud, rootURL: iCloud))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: storage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where isDirectory(folder) {
            let name = folder.lastPathComponent
            found.append(MountedVolume(identityKey: "cloud:" + name, name: displayName(forFolder: name),
                                       kind: .cloud, rootURL: folder))
        }
        return found
    }

    /// "GoogleDrive-rosh@example.com" → "Google Drive"; "OneDrive-Personal" → "OneDrive (Personal)".
    /// An account's email never shows: it's in the folder name only.
    public static func displayName(forFolder folder: String) -> String {
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let known: [String: String] = [
            "GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box",
            "SynologyDrive": "Synology Drive", "pCloudDrive": "pCloud Drive", "ProtonDrive": "Proton Drive",
        ]
        let provider = known[parts[0]] ?? parts[0]
        guard parts.count == 2 else { return provider }
        let account = parts[1]
        if account.contains("@") || account.isEmpty || account == parts[0] { return provider }
        return "\(provider) (\(account))"
    }

    /// The provider folder holding `url`, if it is in one. Compares resolved paths.
    public static func provider(containing url: URL, in providers: [MountedVolume]) -> MountedVolume? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return providers.first { provider in
            let root = provider.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Whether a file in a cloud drive folder is on this Mac yet, and getting it when it isn't.
/// Checking never downloads: it reads the file's flags and the provider's status only.
public enum CloudFiles {
    /// `SF_DATALESS`: the file's bytes are still in the cloud (a File Provider placeholder).
    static let datalessFlag: UInt32 = 0x4000_0000

    /// True when opening `url` would have to download it first.
    public static func needsDownload(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus {
            return status == .notDownloaded
        }
        return isDataless(url)
    }

    static func isDataless(_ url: URL) -> Bool {
        #if canImport(Darwin)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
        #else
        return false
        #endif
    }

    /// Bytes to download before `urls` can all be read: the sizes of those not on this Mac yet.
    /// A placeholder knows its file's size, so nothing is downloaded to find out.
    public static func downloadSize(of urls: [URL]) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for url in urls where needsDownload(url) {
            files += 1
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files, bytes)
    }
}

/// One download of a cloud file, cancellable. The provider's app does the transfer; Atelier asks
/// for the file with a coordinated read, which makes the provider bring its bytes to this Mac.
/// Runs off the main thread; nothing is read into memory beyond the first byte.
public final class CloudDownload: @unchecked Sendable {
    private let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        lock.withLock { cancelled = true }
        coordinator.cancel()
    }

    /// Returns once `url` is on this Mac. Throws `CancellationError` when cancelled.
    public func run(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
                var coordinationError: NSError?
                var readError: Error?
                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    do {
                        let handle = try FileHandle(forReadingFrom: readable)
                        defer { try? handle.close() }
                        _ = try handle.read(upToCount: 1)
                    } catch {
                        readError = error
                    }
                }
                if isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let error = coordinationError ?? readError {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
