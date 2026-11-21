import AppKit
import AtelierCore
import SwiftUI

/// One photo at a time from the 2560 px preview. Arrow keys step, Esc or G returns to the grid.
struct LoupeView: View {
    @EnvironmentObject private var model: LibraryModel
    /// Redraws on new previews (`PreviewRevision`).
    @ObservedObject private var previewRevision = PreviewRevision.shared
    /// The model's zoom, watched here so the full-resolution load follows it.
    @ObservedObject var zoom: ZoomState
    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var loadedID: Int64?
    /// The full-size photo's size for `image`, which can still be the previous photo's.
    @State private var imagePixelSize: CGSize?
    /// Full-resolution render, loaded once the photo is zoomed past fit.
    @State private var fullImage: NSImage?
    @State private var fullKey: FullKey?
    /// The focused photo's camera settings, for the info overlay.
    @State private var info: ShootingInfo?
    /// The last photo stays as it is, at its zoom, until the next one's 2560 px preview is
    /// decoded, which then goes on in one step (as in Develop: `DevelopController.holdsPreviousPhoto`).
    /// Showing the 256 px grid thumbnail first made every change a visible swap (Rosh, Nov 21,
    /// 2026: "what is going on in Loupe, which has a flicker on every change?").
    @StateObject private var hold = PhotoChangeHold(limit: 1.0)
    /// The preview file `image` came from and its date, so the same preview decoded again
    /// (another copy of the same pixels, after any photo's preview was stored) isn't swapped in.
    @State private var shownPreview: (url: URL, modified: Date?)?
    /// Zoomed in, the next photo's preview waits here for its full-size render, so the photo goes
    /// on once, sharp at the zoom, as in Develop (its preview at 100% would be the soft first
    /// picture).
    @State private var pending: (id: Int64, image: NSImage, url: URL?)?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: theme.surround)
                if let image {
                    ZoomableImageView(image: showsFullImage ? fullImage ?? image : image,
                                      pixelSize: imagePixelSize,
                                      zoom: zoom,
                                      dimmed: model.detail?.metadata.flag == .rejected,
                                      onReport: { report in
                                          if zoom.report != report { zoom.report = report }
                                      },
                                      menu: { model.photoMenu(includeZoom: true) },
                                      holdsImage: hold.isHolding)
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
            AdaptiveControlBar(sizingKey: false) {
                HStack {
                    Text("Double-click the photo to zoom, drag to move around")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer(minLength: 8)
                    ZoomControls(zoom: zoom)
                }
            } compact: {
                HStack {
                    Spacer(minLength: 0)
                    ZoomControls(zoom: zoom)
                }
            } minimum: {
                HStack {
                    Spacer(minLength: 0)
                    ZoomControls(zoom: zoom, compact: true)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .task(id: LoadKey(id: model.focusedID, revision: previewRevision.value)) {
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

    /// The full-size render is of the photo on screen (`loadedID`, which is the last photo until
    /// the next one's preview is in), so it stays up while another photo loads instead of the
    /// photo stepping down to its preview first.
    private var showsFullImage: Bool {
        guard let fullKey, fullKey.id == loadedID else { return false }
        return fullKey.revision == previewRevision.value || loadedID != model.focusedID
    }

    private var currentFullKey: FullKey? {
        model.focusedID.map { FullKey(id: $0, revision: previewRevision.value) }
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
            loadedID = nil
            return
        }
        let previewURL = model.thumbnailURL(for: id, size: .preview)
        let zoomed = zoom.report.isZoomedPastFit
        if loadedID != id, zoomed, image != nil {
            // Zoomed in: the last photo stays until this one's full-size render is in
            // (`loadFullResolution`), with its preview ready under it.
            hold.begin()
            pending = nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(hold.limit))
                guard model.focusedID == id, loadedID != id else { return }
                if let pending, pending.id == id { show(pending.image, for: id, from: pending.url) }
                else if let thumbnail = ThumbnailLoader.shared.cached(id) { show(thumbnail, for: id) }
            }
            let loaded: NSImage?
            if let previewURL { loaded = await PreviewImages.shared.load(id, at: previewURL) } else { loaded = ThumbnailLoader.shared.cached(id) }
            guard model.focusedID == id, loadedID != id, let loaded else { return }
            pending = (id, loaded, previewURL)
            // Its full-size render came first.
            if let fullKey, fullKey == currentFullKey { show(loaded, for: id, from: previewURL) }
            return
        }
        if loadedID != id {
            // Never clear to the background: keep the last photo until this one is ready. Its
            // decoded preview goes up at once when it is in memory. Otherwise the last photo stays
            // while the preview decodes (tens of ms), rather than the grid thumbnail and then the
            // preview; only with no preview yet, or after `holdLimit`, does the thumbnail show.
            if let previewURL, let cached = PreviewImages.shared.cached(id, at: previewURL) {
                // Decoded already: shown once, not decoded and swapped in again below.
                show(cached, for: id, from: previewURL)
                return
            } else if previewURL != nil, image != nil {
                hold.begin()
                // Past the limit: the thumbnail rather than the last photo.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(hold.limit))
                    guard model.focusedID == id, loadedID != id, let thumbnail = ThumbnailLoader.shared.cached(id) else { return }
                    show(thumbnail, for: id)
                }
            } else if let thumbnail = ThumbnailLoader.shared.cached(id) {
                show(thumbnail, for: id)
            }
        }
        // Fall back to the thumbnail while the full preview is missing or being built.
        let loaded: NSImage?
        if let previewURL {
            loaded = await PreviewImages.shared.load(id, at: previewURL)
        } else if let url = model.thumbnailURL(for: id, size: .thumbnail) {
            loaded = await Task.detached(priority: .userInitiated) { ThumbnailLoader.decode(url) }.value
        } else {
            // Nothing to show until its previews are built; don't leave the last photo up.
            if loadedID != id {
                hold.end(because: nil)
                image = nil
                loadedID = nil
            }
            return
        }
        guard model.focusedID == id else { return }
        guard let loaded else {
            // The preview couldn't be read: the thumbnail, if any, rather than the last photo.
            if hold.isHolding {
                if let thumbnail = ThumbnailLoader.shared.cached(id) { show(thumbnail, for: id) } else { hold.end(because: nil) }
            }
            return
        }
        guard loaded !== image else { return }
        if loadedID == id, let previewURL, let shownPreview, shownPreview.url == previewURL,
           shownPreview.modified == Self.modified(previewURL) { return }
        show(loaded, for: id, from: previewURL)
    }

    private func show(_ shown: NSImage, for id: Int64, from preview: URL? = nil) {
        image = shown
        imagePixelSize = pixelSize
        loadedID = id
        shownPreview = preview.map { ($0, Self.modified($0)) }
        if pending?.id == id { pending = nil }
        hold.end(because: nil)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Renders the original with its develop settings at full size.
    private func loadFullResolution() async {
        guard let key = wantedFullKey, key != fullKey else { return }
        guard let url = try? model.catalog.readableURL(for: key.id, cache: model.originals),
              let settings = try? model.catalog.developSettings(for: key.id) else { return }
        // The one full-size render every photo view shares (Develop's, when it made it already).
        let rendered = await FullSizeRenders.shared.render(url, settings: settings)
        guard !Task.isCancelled, currentFullKey == key, let rendered else { return }
        fullImage = rendered
        fullKey = key
        // Zoomed in on a newly selected photo: it goes on now, sharp (`pending`).
        if loadedID != key.id, model.focusedID == key.id {
            if let pending, pending.id == key.id { show(pending.image, for: key.id, from: pending.url) }
            else { show(rendered, for: key.id) }
        }
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
