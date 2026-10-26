import AppKit
import AtelierCore
import SwiftUI

/// One photo at a time from the 2560 px preview. Arrow keys step, Esc or G returns to the grid.
struct LoupeView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var image: NSImage?
    @State private var loadedID: Int64?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: .underPageBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .opacity(model.detail?.metadata.flag == .rejected ? 0.4 : 1)
            } else if model.focusedID != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let detail = model.detail {
                LoupeInfo(detail: detail)
                    .padding(14)
            }
        }
        .task(id: LoadKey(id: model.focusedID, revision: model.previewRevision)) {
            await load()
        }
    }

    private struct LoadKey: Equatable {
        var id: Int64?
        var revision: Int
    }

    private func load() async {
        guard let id = model.focusedID else {
            image = nil
            return
        }
        if loadedID != id { image = nil }
        // Fall back to the thumbnail while the full preview is missing or being built.
        let url = model.thumbnailURL(for: id, size: .preview) ?? model.thumbnailURL(for: id, size: .thumbnail)
        guard let url else { return }
        let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if model.focusedID == id {
            image = loaded
            loadedID = id
        }
    }
}

private struct LoupeInfo: View {
    let detail: AssetDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(detail.asset.filename).font(.headline)
            HStack(spacing: 8) {
                if detail.metadata.rating > 0 {
                    Text(String(repeating: "★", count: detail.metadata.rating))
                }
                switch detail.metadata.flag {
                case .picked: Text("Picked")
                case .rejected: Text("Rejected")
                case .none: EmptyView()
                }
                if let label = detail.metadata.colorLabel {
                    Text(label.rawValue)
                }
                if detail.fileURL == nil {
                    Text("Offline").foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
