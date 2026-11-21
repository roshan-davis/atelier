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
    /// Full-resolution render of a photo (`FullSizeRenders`), loaded once it is shown past Fit.
    @State private var fullImage: NSImage?
    @State private var fullKey: FullKey?
    /// The photo whose full-size render is on its way.
    @State private var fullLoadingID: Int64?
    /// The focused photo's camera settings, for the info overlay.
    @State private var info: ShootingInfo?
    /// The preview file `image` came from and its date, so the same preview decoded again
    /// (another copy of the same pixels) isn't swapped in.
    @State private var shownPreview: (url: URL, modified: Date?)?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: theme.surround)
                if let image {
                    // Loupe only hands over its best picture of the photo and says whether a
                    // sharper one is coming; the photo view decides what goes on screen
                    // (`ZoomScrollView.offer`): never softer than the zoom needs while a sharper
                    // picture is on its way, never a softer one in place of a sharper one.
                    ZoomableImageView(image: image,
                                      pixelSize: imagePixelSize,
                                      zoom: zoom,
                                      dimmed: model.detail?.metadata.flag == .rejected,
                                      onReport: { report in
                                          if zoom.report != report { zoom.report = report }
                                      },
                                      menu: { model.photoMenu(includeZoom: true) },
                                      // `image` is of `loadedID`, the last photo until the
                                      // selected one's picture is in: the view holds it until then.
                                      wantedPhotoID: model.focusedID, imagePhotoID: loadedID,
                                      sharperComing: fullLoadingID != nil && fullLoadingID == loadedID,
                                      imageRevision: pictureRevision,
                                      sharperImage: fullKey?.id == loadedID ? fullImage : nil)
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

    /// A full-size render: the photo and its preview file's date (it changes only when that
    /// photo's look does, never because another photo's preview was stored).
    private struct FullKey: Equatable {
        var id: Int64
        var previewModified: Date?
    }

    /// The selected photo's full-size render, made at once when its zoom (the shared level, so
    /// the next photo's own zoom with "return to its last zoom") is past Fit, and otherwise once
    /// the photo has been shown for `fullRest`, so zooming in is sharp from the first frame (it is
    /// handed to the photo view as the sharper picture, used only when the zoom needs it).
    private var wantedFullKey: FullKey? {
        guard let id = model.focusedID else { return nil }
        _ = previewRevision.value
        return FullKey(id: id, previewModified: model.thumbnailURL(for: id, size: .preview).flatMap(Self.modified))
    }

    /// The version of the photo's look the picture shows: its preview file's date (the full-size
    /// render is of the same look).
    private var pictureRevision: Double? {
        (shownPreview?.modified ?? fullKey?.previewModified)?.timeIntervalSinceReferenceDate
    }

    private var pixelSize: CGSize? {
        guard let width = model.detail?.asset.width, let height = model.detail?.asset.height else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The selected photo's preview (or its thumbnail while it has none): decoded off the main
    /// thread and handed to the photo view, which keeps the last photo until then.
    private func load() async {
        guard let id = model.focusedID else {
            image = nil
            loadedID = nil
            return
        }
        let previewURL = model.thumbnailURL(for: id, size: .preview)
        if loadedID != id, let previewURL, let cached = PreviewImages.shared.cached(id, at: previewURL) {
            show(cached, for: id, from: previewURL)
            return
        }
        let loaded: NSImage?
        if let previewURL {
            loaded = await PreviewImages.shared.load(id, at: previewURL)
        } else if let url = model.thumbnailURL(for: id, size: .thumbnail) {
            loaded = await Task.detached(priority: .userInitiated) { ThumbnailLoader.decode(url) }.value
        } else {
            // Nothing to show until its previews are built; don't leave the last photo up.
            if loadedID != id {
                image = nil
                loadedID = nil
            }
            return
        }
        guard model.focusedID == id else { return }
        guard let loaded else {
            if loadedID != id, let thumbnail = ThumbnailLoader.shared.cached(id) { show(thumbnail, for: id) }
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
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Renders the photo with its develop settings at full size, through the one full-size render
    /// every photo view shares.
    private static let fullRest: Duration = .milliseconds(500)

    private func loadFullResolution() async {
        guard let key = wantedFullKey, key != fullKey else { return }
        if zoom.level == .fit {
            try? await Task.sleep(for: Self.fullRest)
            guard !Task.isCancelled, wantedFullKey == key else { return }
        }
        guard let url = try? model.catalog.readableURL(for: key.id, cache: model.originals),
              let settings = try? model.catalog.developSettings(for: key.id) else { return }
        fullLoadingID = key.id
        let rendered = await FullSizeRenders.shared.render(url, settings: settings)
        if fullLoadingID == key.id { fullLoadingID = nil }
        guard !Task.isCancelled, let rendered, model.focusedID == key.id else { return }
        fullImage = rendered
        fullKey = key
        // Its preview may not be in yet (zoomed in, the full size can come first).
        if loadedID != key.id {
            image = rendered
            imagePixelSize = pixelSize
            loadedID = key.id
            shownPreview = nil
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
