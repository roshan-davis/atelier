import AppKit
import AtelierCore
import SwiftUI

/// One photo at a time from the 2560 px preview. Arrow keys step, Esc or G returns to the grid.
struct LoupeView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var loadedID: Int64?
    /// Full-resolution render, loaded once the photo is zoomed past fit.
    @State private var fullImage: NSImage?
    @State private var fullKey: FullKey?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: theme.surround)
                if let image {
                    ZoomableImageView(image: fullKey == currentFullKey ? fullImage ?? image : image,
                                      pixelSize: pixelSize,
                                      zoom: $model.zoom,
                                      dimmed: model.detail?.metadata.flag == .rejected,
                                      onReport: { report in
                                          if model.zoomReport != report { model.zoomReport = report }
                                      },
                                      menu: { model.photoMenu(includeZoom: true) })
                } else if model.focusedID != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let detail = model.detail {
                    LoupeInfo(detail: detail)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Click the photo to zoom, drag to move around")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer(minLength: 8)
                    ZoomControls(zoom: $model.zoom, report: model.zoomReport)
                }
                HStack {
                    Spacer(minLength: 0)
                    ZoomControls(zoom: $model.zoom, report: model.zoomReport)
                }
                HStack {
                    Spacer(minLength: 0)
                    ZoomControls(zoom: $model.zoom, report: model.zoomReport, compact: true)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .task(id: LoadKey(id: model.focusedID, revision: model.previewRevision)) {
            await load()
        }
        .task(id: wantedFullKey) {
            await loadFullResolution()
        }
    }

    private struct LoadKey: Equatable {
        var id: Int64?
        var revision: Int
    }

    private struct FullKey: Equatable {
        var id: Int64
        var revision: Int
    }

    private var currentFullKey: FullKey? {
        model.focusedID.map { FullKey(id: $0, revision: model.previewRevision) }
    }

    private var wantedFullKey: FullKey? {
        model.zoomReport.isZoomedPastFit ? currentFullKey : nil
    }

    private var pixelSize: CGSize? {
        guard let width = model.detail?.asset.width, let height = model.detail?.asset.height else { return nil }
        return CGSize(width: width, height: height)
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

    /// Renders the original with its develop settings at full size.
    private func loadFullResolution() async {
        guard let key = wantedFullKey, key != fullKey else { return }
        guard let url = try? model.catalog.fileURL(for: key.id),
              let settings = try? model.catalog.developSettings(for: key.id) else { return }
        let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cgImage = DevelopRenderer.shared.session(for: url, maxPixelSize: nil)?.render(settings) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        guard !Task.isCancelled, currentFullKey == key, let rendered else { return }
        fullImage = rendered
        fullKey = key
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
