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
    @Environment(\.theme) private var theme
    @State private var position = ScrollPosition(edge: .top)
    @State private var geometry: ScrollGeometry?
    /// Each row's frame in the list's content.
    @State private var rowFrames: [Int: CGRect] = [:]

    private static let space = "cullList"

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if cull.isAnalyzing {
                    analysisStatus
                }
                let rows = cull.rows
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    rowView(index, row, isLast: index == rows.count - 1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                            rowFrames[index] = $0
                        }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(.named(Self.space))
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in
            geometry = new
            // While analyzing, as many photos per row as fit.
            let columns = max(1, Int((new.containerSize.width - 32 + CullTile.spacing) / CullTile.stride))
            if cull.columns != columns { cull.columns = columns }
        }
        .background(Color(nsColor: theme.gridBackground))
        .onChange(of: cull.reveal) { _, reveal in
            guard let reveal, let geometry,
                  let row = cull.rows.firstIndex(where: { $0.contains(reveal.id) }), let frame = rowFrames[row],
                  let y = ScrollReveal.offset(item: Double(frame.minY)...Double(frame.maxY),
                                              visibleStart: Double(geometry.visibleRect.minY),
                                              visibleLength: Double(geometry.visibleRect.height),
                                              contentLength: Double(geometry.contentSize.height), margin: 12)
            else { return }
            withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(y: CGFloat(y)) }
        }
        .onChange(of: cull.isAnalyzing) { _, analyzing in
            // The groups replace the analysis list: start again at the top.
            if !analyzing { position.scrollTo(edge: .top) }
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
            CullGroupCard(cull: cull, ids: ids, index: index, isSingles: isSingles)
        }
    }

    /// Above the photos while they are analyzed.
    private var analysisStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Checking sharpness, faces and similar shots")
                    .font(.headline)
                Spacer()
                Text("\(cull.analyzed) of \(cull.photos.count)")
                    .monospacedDigit()
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
    @Environment(\.theme) private var theme
    @State private var position = ScrollPosition(edge: .leading)
    @State private var geometry: ScrollGeometry?

    var body: some View {
        let kept = ids.filter { cull.kept.contains($0) }.count
        let title = isSingles ? "Single shots" : (cull.isReview ? "Culled together" : "Group \(index + 1)")
        let kind = isSingles || cull.isReview ? nil : (cull.isSameFrame(ids) ? "Same frame" : "Similar shots")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isSingles ? "photo" : "square.stack.3d.down.right")
                    .foregroundStyle(.secondary)
                Text(title).font(.headline)
                if let kind {
                    Text(kind)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .help(kind == "Same frame" ? "Framed alike: people moved a little, blinked or changed expression"
                              : "The same scene, zoomed, recomposed or refocused")
                }
                Text("\(ids.count) photo\(ids.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if !isSingles, let time = cull.photos[ids[0]].captureTime {
                    Text(time.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(kept == 0 ? "None kept" : "\(kept) kept")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(kept == 0 ? Color.orange.opacity(0.25) : Color.green.opacity(0.22), in: Capsule())
            }
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: CullTile.spacing) {
                    ForEach(ids, id: \.self) { CullTileButton(cull: cull, id: $0) }
                }
                .padding(.bottom, 4)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in geometry = new }
        }
        .padding(12)
        .background(Color(nsColor: theme.panel).opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(ids.contains(cull.focused ?? -1) ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18)))
        // Tiles are a fixed width, so a photo's place in the row is known without measuring.
        .onChange(of: cull.reveal) { _, reveal in
            guard let reveal, let column = ids.firstIndex(of: reveal.id), let geometry else { return }
            let start = Double(column) * CullTile.stride
            guard let x = ScrollReveal.offset(item: start...(start + CullTile.width),
                                              visibleStart: Double(geometry.visibleRect.minX),
                                              visibleLength: Double(geometry.visibleRect.width),
                                              contentLength: Double(geometry.contentSize.width), margin: 8)
            else { return }
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
            .onTapGesture(count: 2) { cull.toggle(id) }
            .onTapGesture { cull.focus(id) }
            .contextMenu {
                Button(cull.kept.contains(id) ? "Drop" : "Keep") { cull.toggle(id) }
            }
    }
}
