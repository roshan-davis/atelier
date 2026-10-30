import Combine
import Foundation
import GRDB

/// Startup state shared by the recovery window and the app. A failed attempt never
/// supplies a catalog to library commands, session saving or quit-time backups.
@MainActor
public final class CatalogOpening: ObservableObject {
    public let packageURL: URL
    @Published public private(set) var catalog: Catalog?
    @Published public private(set) var failureReason: String?
    @Published public private(set) var isOpening = false

    public init(packageURL: URL = Catalog.defaultPackageURL) {
        self.packageURL = packageURL
    }

    /// Retries the same location. No fallback catalog, reset or automatic restore.
    public func open() async {
        guard !isOpening, catalog == nil else { return }
        isOpening = true
        failureReason = nil
        defer { isOpening = false }
        let url = packageURL
        do {
            catalog = try await Task.detached(priority: .userInitiated) {
                try Catalog(packageURL: url)
            }.value
        } catch let error as DatabaseError {
            // The SQL statement is an implementation detail, not a useful recovery instruction.
            if error.resultCode == .SQLITE_NOTADB || error.resultCode == .SQLITE_CORRUPT {
                failureReason = "The catalog database is damaged or is not a valid SQLite database."
            } else {
                failureReason = error.message ?? error.localizedDescription
            }
        } catch {
            failureReason = error.localizedDescription
        }
    }
}
