import AppKit
import AtelierCore
import ImageIO
import SwiftUI

/// Camera settings read from each file once per launch, off the main thread, for the Library's
/// right panel and the Loupe overlay. Develop reads its own when a photo opens.
@MainActor
enum ShootingInfoCache {
    private final class Entry {
        let info: ShootingInfo
        init(_ info: ShootingInfo) { self.info = info }
    }

    /// Bounded (AT-076 M4): a few thousand photos' worth, the ones looked at last kept; one let
    /// go is read again from its file when shown.
    private static let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.countLimit = 2000
        return cache
    }()

    static func info(for url: URL) async -> ShootingInfo {
        if let cached = cache.object(forKey: url as NSURL) { return cached.info }
        let info = await Task.detached(priority: .userInitiated) { ShootingInfo(url: url) }.value
        cache.setObject(Entry(info), forKey: url as NSURL)
        return info
    }
}

/// Lightroom's line under the histogram: "ISO 400   50 mm   ƒ/2.8   1/250 sec", spread across the
/// width, with the camera, lens and exposure compensation on hover.
struct ShootingInfoLine: View {
    /// Nil while it is being read.
    let info: ShootingInfo?

    var body: some View {
        if let info, !info.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(info.parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Spacer(minLength: 6) }
                    Text(part).lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            .help(info.details)
        } else if info != nil {
            Text("No camera settings in this file").foregroundStyle(.tertiary)
        } else {
            Text(" ")
        }
    }
}

/// The Library's histogram, as in Lightroom's Library module: drawn from the photo's preview (so
/// it shows the edited photo), with clipping triangles and the camera settings underneath. It
/// only shows; editing is in Develop.
struct LibraryHistogram: View {
    let histogram: Histogram?
    let info: ShootingInfo?
    let isLoading: Bool
    /// Lightroom's line under the histogram: "Original Photo", "Original + Smart Preview",
    /// "Smart Preview" or "Photo is missing" (AT-079d); nil while it is being worked out.
    var previews: PhotoPreviews? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HistogramGraph(histogram: histogram)
                .frame(height: 72)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    if histogram == nil, isLoading { ProgressView().controlSize(.small) }
                }
                .overlay(alignment: .topLeading) { triangle(shadows: true) }
                .overlay(alignment: .topTrailing) { triangle(shadows: false) }
            ShootingInfoLine(info: info)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 14)
            if let previews {
                Label(previews.title, systemImage: previews.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .help(previews.help)
            }
        }
    }

    private func triangle(shadows: Bool) -> some View {
        HistogramGraph.triangle(shadows: shadows,
                                       color: HistogramGraph.clipColor(shadows ? histogram?.shadowChannels : histogram?.highlightChannels))
            .padding(3)
            .help(HistogramGraph.clipHelp(shadows: shadows, histogram: histogram))
    }

    /// The histogram of a preview file.
    nonisolated static func load(from url: URL) -> Histogram? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Histogram(image: image)
    }
}

/// What Atelier can edit a photo from: its original, its smart preview, both or neither.
enum PhotoPreviews: Equatable {
    case original, originalAndSmart, smart, missing

    init(originalOnline: Bool, hasSmartPreview: Bool) {
        switch (originalOnline, hasSmartPreview) {
        case (true, false): self = .original
        case (true, true): self = .originalAndSmart
        case (false, true): self = .smart
        case (false, false): self = .missing
        }
    }

    var title: String {
        switch self {
        case .original: "Original Photo"
        case .originalAndSmart: "Original + Smart Preview"
        case .smart: "Smart Preview"
        case .missing: "Photo is missing"
        }
    }

    var symbol: String {
        switch self {
        case .original: "photo"
        case .originalAndSmart, .smart: "square.on.square.dashed"
        case .missing: "exclamationmark.triangle"
        }
    }

    var help: String {
        switch self {
        case .original: "Develop edits the original."
        case .originalAndSmart: "Develop edits the original; the smart preview is used while it is offline."
        case .smart: "The original is offline. Develop edits the smart preview, and the edits apply to the original when it is back."
        case .missing: "The original is offline and there is no smart preview, so it can't be edited until it is back."
        }
    }
}
