import AppKit
import AtelierCore
import SwiftUI

/// The Cull view's list: one row per group of similar shots (single shots last), or, while the
/// photos are analyzed, every photo wrapped into rows.
///
/// Scrolling follows Finder and Lightroom's grid: a click never moves the list, and the arrow
/// keys move it only when the photo they land on isn't fully visible, by the least that shows
/// it (up and down for its row, left and right inside a long row). The list keeps its own
/// scroll position, row frames and visible area, so the decision is exact (`ScrollReveal`)
/// rather than left to `ScrollViewReader`, which jumps in nested and lazy stacks.
struct CullList: View {
    @ObservedObject var cull: CullModel
    /// The list's size, given by the Cull view's own layout rather than measured, so rows are
    /// always laid out to exactly this width from the first frame.
    let size: CGSize
    @Environment(\.theme) private var theme
    @State private var position = ScrollPosition(edge: .top)
    /// How far the list is scrolled; zero until the user or a key scrolls it.
    @State private var offset: CGFloat = 0
    /// Each row's frame in the list's content.
    @State private var rowFrames: [Int: CGRect] = [:]

    nonisolated private static let space = "cullList"
    private static let padding = 16.0

    /// The width inside the list's padding, which every row and card fits.
    private var innerWidth: Double { max(0, Double(size.width) - Self.padding * 2) }
    /// While analyzing, as many photos per row as fit.
    private var columns: Int { max(1, Int((innerWidth + CullTile.spacing) / CullTile.stride)) }

    var body: some View {
        let columns = self.columns
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if cull.isAnalyzing {
                    analysisStatus
                        .frame(width: innerWidth, alignment: .leading)
                }
                let rows = cull.rows
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    rowView(index, row, isLast: index == rows.count - 1)
                        .frame(width: innerWidth, alignment: .leading)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                            rowFrames[index] = $0
                        }
                }
            }
            .padding(Self.padding)
            .frame(width: size.width, alignment: .leading)
            .coordinateSpace(.named(Self.space))
        }
        .frame(width: size.width, height: size.height)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, new in offset = new }
        .onAppear { if cull.columns != columns { cull.columns = columns } }
        .onChange(of: columns) { _, columns in cull.columns = columns }
        .background(Color(nsColor: theme.gridBackground))
        .onChange(of: cull.reveal) { _, reveal in
            let contentHeight = (rowFrames.values.map(\.maxY).max() ?? 0) + Self.padding
            guard let reveal, size.height > 0,
                  let row = cull.rows.firstIndex(where: { $0.contains(reveal.id) }), let frame = rowFrames[row],
                  let y = ScrollReveal.offset(item: Double(frame.minY)...Double(frame.maxY),
                                              visibleStart: Double(offset), visibleLength: Double(size.height),
                                              contentLength: Double(contentHeight), margin: 12)
            else { return }
            offset = CGFloat(y)
            withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(y: CGFloat(y)) }
        }
        .onChange(of: cull.isAnalyzing) { _, analyzing in
            // The groups replace the analysis list: start again at the top.
            if !analyzing {
                offset = 0
                position.scrollTo(edge: .top)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ index: Int, _ ids: [Int], isLast: Bool) -> some View {
        if cull.isAnalyzing {
            HStack(spacing: CullTile.spacing) {
                ForEach(ids, id: \.self) { CullTileButton(cull: cull, id: $0) }
            }
        } else {
            let isSingles = isLast && !cull.singles.isEmpty
            // The card's padding is 12 on each side.
            CullGroupCard(cull: cull, ids: ids, index: index, isSingles: isSingles, width: innerWidth - 24)
        }
    }

    /// Above the photos while they are analyzed.
    private var analysisStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Checking sharpness, faces and similar shots")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(cull.analyzed) of \(cull.photos.count)")
                    .monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(cull.analyzed), total: Double(max(cull.photos.count, 1)))
            Text(timeLeft.map { "\($0). " } ?? "")
                + Text("Groups and suggested keepers appear when every photo is checked. The arrow keys already work.")
        }
        .font(.callout)
        .padding(12)
        .background(Color(nsColor: theme.panel).opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
    }

    private var timeLeft: String? {
        guard let start = cull.analysisStarted, cull.analyzed >= 4 else { return nil }
        let left = Date().timeIntervalSince(start) / Double(cull.analyzed) * Double(cull.photos.count - cull.analyzed)
        let time = DateComponentsFormatter()
        time.unitsStyle = .full
        time.maximumUnitCount = 1
        time.allowedUnits = left < 60 ? [.second] : [.hour, .minute]
        return time.string(from: max(left, 1).rounded(.up)).map { "About \($0) left" }
    }
}

/// One group of similar shots (or the single shots) with its photos in a row that scrolls
/// sideways when it is longer than the list is wide.
private struct CullGroupCard: View {
    @ObservedObject var cull: CullModel
    let ids: [Int]
    let index: Int
    let isSingles: Bool
    /// The width of the row of photos, from the list's width.
    let width: Double
    @Environment(\.theme) private var theme
    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0

    var body: some View {
        let kept = ids.filter { cull.kept.contains($0) }.count
        let title = isSingles ? "Single shots" : (cull.isReview ? "Culled together" : "Group \(index + 1)")
        let kind = isSingles || cull.isReview ? nil : (cull.isSameFrame(ids) ? "Same frame" : "Similar shots")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isSingles ? "photo" : "square.stack.3d.down.right")
                    .foregroundStyle(.secondary)
                Text(title).font(.headline).lineLimit(1).fixedSize()
                if let kind {
                    Text(kind)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .fixedSize()
                        .help(kind == "Same frame" ? "Framed alike: people moved a little, blinked or changed expression"
                              : "The same scene, zoomed, recomposed or refocused")
                }
                // The count and time give way (truncate) before the card grows past the list.
                Text("\(ids.count) photo\(ids.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !isSingles, let time = cull.photos[ids[0]].captureTime {
                    Text(time.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 4)
                Text(kept == 0 ? "None kept" : "\(kept) kept")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(kept == 0 ? Color.orange.opacity(0.25) : Color.green.opacity(0.22), in: Capsule())
                    .fixedSize()
            }
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: CullTile.spacing) {
                    ForEach(ids, id: \.self) { CullTileButton(cull: cull, id: $0) }
                }
                .padding(.bottom, 4)
            }
            .frame(width: max(0, width))
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, new in offset = new }
        }
        .frame(width: max(0, width), alignment: .leading)
        .padding(12)
        .background(Color(nsColor: theme.panel).opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(ids.contains(cull.focused ?? -1) ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18)))
        // Tiles are a fixed width, so a photo's place in the row is known without measuring.
        .onChange(of: cull.reveal) { _, reveal in
            guard let reveal, let column = ids.firstIndex(of: reveal.id), width > 0 else { return }
            let start = Double(column) * CullTile.stride
            guard let x = ScrollReveal.offset(item: start...(start + CullTile.width),
                                              visibleStart: Double(offset), visibleLength: width,
                                              contentLength: Double(ids.count) * CullTile.stride - CullTile.spacing,
                                              margin: 8)
            else { return }
            offset = CGFloat(x)
            withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(x: CGFloat(x)) }
        }
    }
}

/// A tile with its clicks: click looks, double-click keeps or drops. Never scrolls the list.
private struct CullTileButton: View {
    @ObservedObject var cull: CullModel
    let id: Int

    var body: some View {
        CullTile(photo: cull.photos[id], isKept: cull.kept.contains(id),
                 isSuggested: cull.suggested.contains(id), isFocused: cull.focused == id,
                 dimsWhenDropped: !cull.isAnalyzing)
            // A click focuses at once; a double-click focuses, then keeps or drops.
            .onClick { cull.focus(id) } doubleClick: { cull.toggle(id) }
            .contextMenu {
                Button(cull.kept.contains(id) ? "Drop" : "Keep") { cull.toggle(id) }
            }
    }
}
