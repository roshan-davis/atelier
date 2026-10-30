import AppKit
import AtelierCore
import SwiftUI

/// One photo at a time from the 2560 px preview. Arrow keys step, Esc or G returns to the grid.
struct LoupeView: View {
    @EnvironmentObject private var model: LibraryModel
    /// The model's zoom, watched here so the full-resolution load follows it.
    @ObservedObject var zoom: ZoomState
    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var loadedID: Int64?
    /// Full-resolution render, loaded once the photo is zoomed past fit.
    @State private var fullImage: NSImage?
    @State private var fullKey: FullKey?
    /// The focused photo's camera settings, for the info overlay.
    @State private var info: ShootingInfo?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: theme.surround)
                if let image {
                    ZoomableImageView(image: fullKey == currentFullKey ? fullImage ?? image : image,
                                      pixelSize: pixelSize,
                                      zoom: zoom,
                                      dimmed: model.detail?.metadata.flag == .rejected,
                                      onReport: { report in
                                          if zoom.report != report { zoom.report = report }
                                      },
                                      menu: { model.photoMenu(includeZoom: true) })
                } else if model.focusedID != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let detail = model.detail {
                    LoupeInfo(detail: detail, copyName: model.virtualCopyName(detail.asset.id), info: info)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Double-click the photo to zoom, drag to move around")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer(minLength: 8)
                    ZoomControls(zoom: zoom)
                }
                HStack {
                    Spacer(minLength: 0)
                    ZoomControls(zoom: zoom)
                }
                HStack {
                    Spacer(minLength: 0)
                    ZoomControls(zoom: zoom, compact: true)
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
        .task(id: model.detail?.fileURL) {
            info = nil
            guard let url = model.detail?.fileURL else { return }
            let loaded = await ShootingInfoCache.info(for: url)
            if !Task.isCancelled { info = loaded }
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
        zoom.report.isZoomedPastFit ? currentFullKey : nil
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

/// Lightroom's Loupe info overlay: the file, when it was taken and its size, then how it was
/// taken ("1/250 sec at ƒ/2.8, ISO 400, 50 mm" and the lens), then rating, flag and label.
private struct LoupeInfo: View {
    let detail: AssetDetail
    let copyName: String?
    let info: ShootingInfo?

    private var captureLine: String? {
        var parts: [String] = []
        if let date = detail.asset.captureTime { parts.append(date.formatted(date: .abbreviated, time: .standard)) }
        if let width = detail.asset.width, let height = detail.asset.height { parts.append("\(width) × \(height)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var settingsLine: String? {
        let parts = [info?.summary, info?.lens ?? detail.asset.lens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var hasStatus: Bool {
        detail.metadata.rating > 0 || detail.metadata.flag != Flag.none || detail.metadata.colorLabel != nil || detail.fileURL == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(detail.asset.filename + (copyName.map { " · \($0)" } ?? "")).font(.headline)
            if let captureLine {
                Text(captureLine).foregroundStyle(.secondary)
            }
            if let settingsLine {
                Text(settingsLine).foregroundStyle(.secondary)
            }
            if hasStatus {
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
            }
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
