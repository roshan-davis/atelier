import AtelierCore
import Foundation

/// How a download of a cloud original ended (AT-079b).
enum CloudOriginalResult: Sendable {
    case ready
    case cancelled
    case failed(String)
}

/// Downloading originals that are still only in a cloud drive folder (AT-079b). The provider's app
/// does the transfer; Atelier asks for the file off the main thread and shows it in the status bar
/// with Cancel, while the photo's preview stays on screen. One download at a time: opening another
/// photo cancels the one before, so the photo you're on never waits behind one you passed.
extension LibraryModel {
    func downloadOriginal(_ assetID: Int64, at url: URL) async -> CloudOriginalResult {
        cloudDownload?.download.cancel()
        let download = CloudDownload()
        cloudDownload = (assetID, download)
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let size = bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
        let provider = providerName(for: url)
        downloadProgress = ImportStatus(phase: "Downloading \(url.lastPathComponent)\(size) from \(provider)…", fraction: nil)
        let result: CloudOriginalResult
        do {
            try await download.run(url)
            result = .ready
        } catch is CancellationError {
            result = .cancelled
        } catch {
            result = .failed("Couldn't download \(url.lastPathComponent) from \(provider): \(error.localizedDescription)")
        }
        // A newer download replaced this one: leave its progress alone.
        if cloudDownload?.download === download {
            cloudDownload = nil
            downloadProgress = nil
        }
        if case .ready = result { markDownloaded(assetID) }
        return result
    }

    func cancelCloudDownload() {
        cloudDownload?.download.cancel()
    }

    /// The grid's cloud badge goes as soon as the file is here (the folder isn't watched).
    private func markDownloaded(_ assetID: Int64) {
        if let index = rows.firstIndex(where: { $0.id == assetID }), rows[index].notDownloaded {
            rows[index].notDownloaded = false
        }
    }

    /// "Dropbox", "iCloud Drive": the location holding the file, else its provider folder.
    private func providerName(for url: URL) -> String {
        let path = url.path
        if let info = sidebar.locations.first(where: { info in
            guard info.location.kind == .cloudFolder, let root = info.rootURL?.path else { return false }
            return path.hasPrefix(root + "/")
        }) {
            return info.location.name
        }
        return CloudFolders.provider(containing: url, in: CloudFolders.providers())?.name ?? "the cloud"
    }
}
