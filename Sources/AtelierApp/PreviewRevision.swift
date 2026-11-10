import Combine

/// Counts preview updates (`LibraryModel.previewRevision`). Views that show previews (Grid,
/// Filmstrip, Loupe, the Info panel) watch this instead of the whole `LibraryModel`, so a saved
/// edit's new preview redraws them and not the Develop panels (AT-039 D5).
@MainActor
final class PreviewRevision: ObservableObject {
    static let shared = PreviewRevision()
    @Published var value = 0
}
