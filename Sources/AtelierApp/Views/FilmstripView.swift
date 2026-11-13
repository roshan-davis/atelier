import AppKit
import AtelierCore
import SwiftUI

/// Lightroom's Filmstrip: the photos of the current source in a strip across the bottom of the
/// whole window, with the photo being worked on highlighted. The header (`FilmstripHeader`) picks
/// the source, filter and order. The arrow tab on the bottom edge (or View > Show Filmstrip, F6)
/// collapses and opens it; the top edge drags to resize. Both are remembered.
struct FilmstripView: View {
    @EnvironmentObject private var model: LibraryModel
    /// Redraws on new previews (`PreviewRevision`).
    @ObservedObject private var previewRevision = PreviewRevision.shared
    @Environment(\.theme) private var theme
    @AppStorage(Filmstrip.visibleKey) private var isVisible = true
    @AppStorage(Filmstrip.heightKey) private var height = Filmstrip.defaultHeight
    @State private var startHeight: Double?
    /// The thumbnails fully in view, so changing photo scrolls only when the new one is not.
    @State private var visibleIDs: Set<Int64> = []

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                resizeEdge
                FilmstripHeader()
                strip
                    .frame(height: max(Filmstrip.minHeight, min(Filmstrip.maxHeight, height)))
            }
            handle
        }
        .background(Color(nsColor: theme.panel))
    }

    // MARK: Parts

    /// The top edge: drag up or down to make the thumbnails bigger or smaller.
    private var resizeEdge: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startHeight ?? height
                            startHeight = start
                            height = min(Filmstrip.maxHeight, max(Filmstrip.minHeight, start - value.translation.height))
                        }
                        .onEnded { _ in startHeight = nil })
                    .cursor(.rowResize)
            )
            .help("Drag to resize the Filmstrip")
    }

    private var strip: some View {
        GeometryReader { geometry in
            let cellHeight = max(40, geometry.size.height - 2 * Filmstrip.stripPadding.height)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: Filmstrip.cellSpacing) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            FilmstripCell(row: row, index: index + 1,
                                          size: CGSize(width: (cellHeight * Filmstrip.cellAspect).rounded(), height: cellHeight),
                                          state: ThumbnailState(isFocused: model.focusedID == row.id,
                                                                isSelected: model.selection.contains(row.id)),
                                          revision: previewRevision.value)
                                .id(row.id)
                                .onTapGesture(count: 2) {
                                    model.selection = [row.id]
                                    model.focusedID = row.id
                                    if model.mode == .grid { model.openLoupe() }
                                }
                                .onTapGesture { select(row.id) }
                                .overlay(RightClickMenu { model.filmstripMenu(for: row.id) })
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, Filmstrip.stripPadding.width)
                    .padding(.vertical, Filmstrip.stripPadding.height)
                }
                .onScrollTargetVisibilityChange(idType: Int64.self, threshold: 0.95) { ids in
                    visibleIDs = Set(ids)
                }
                .onAppear { if let id = model.focusedID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.focusedID) { _, id in
                    guard let id, let anchor = revealAnchor(for: id) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: anchor) }
                }
            }
        }
        .background(Color(nsColor: theme.gridBackground))
        // Thumbnails scrolled out of view must not draw outside the strip.
        .clipped()
    }

    /// A tab centered on the bottom edge with an arrow: down hides, up shows.
    private var handle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isVisible.toggle() }
        } label: {
            Image(systemName: isVisible ? "chevron.down" : "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 56, height: 14)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5),
                            in: UnevenRoundedRectangle(topLeadingRadius: isVisible ? 0 : 5, bottomLeadingRadius: isVisible ? 5 : 0,
                                                       bottomTrailingRadius: isVisible ? 5 : 0, topTrailingRadius: isVisible ? 0 : 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isVisible ? "Hide the Filmstrip (F6)" : "Show the Filmstrip (F6)")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isVisible ? .top : .bottom)
        .frame(height: 16)
        .overlay(alignment: .top) { if !isVisible { Divider() } }
    }

    // MARK: Behaviour

    /// Where to scroll so `id` shows, or nil when it is already fully in view (as in Lightroom,
    /// the strip stays put). Moving right brings the photo in at the right edge, moving left
    /// at the left edge; a jump from far away centers it.
    private func revealAnchor(for id: Int64) -> UnitPoint? {
        guard !visibleIDs.contains(id) else { return nil }
        guard let new = model.rows.firstIndex(where: { $0.id == id }) else { return nil }
        let shown = model.rows.indices.filter { visibleIDs.contains(model.rows[$0].id) }
        guard let first = shown.first, let last = shown.last else { return .center }
        if new == last + 1 { return .trailing }
        if new == first - 1 { return .leading }
        return .center
    }

    /// Click selects the photo; ⌘-click adds or removes it; ⇧-click selects a run.
    private func select(_ id: Int64) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(id) {
                model.selection.remove(id)
                if model.focusedID == id { model.focusedID = model.selection.first }
            } else {
                model.selection.insert(id)
                model.focusedID = id
            }
        } else if flags.contains(.shift), let anchor = model.focusedID,
                  let from = model.rows.firstIndex(where: { $0.id == anchor }),
                  let to = model.rows.firstIndex(where: { $0.id == id }) {
            model.selection = Set(model.rows[min(from, to)...max(from, to)].map(\.id))
            model.focusedID = id
        } else {
            model.selection = [id]
            model.focusedID = id
        }
    }
}

enum Filmstrip {
    static let visibleKey = "filmstrip.visible"
    static let heightKey = "filmstrip.height"
    /// The thumbnails' strip, under the header. The default gives 92 pt tall cells, as in the
    /// AT-018 design (138 × 92).
    static let defaultHeight = 104.0
    static let minHeight = 56.0
    static let maxHeight = 220.0
    /// Cells are landscape 3:2, filled with the photo.
    static let cellAspect: CGFloat = 1.5
    static let cellSpacing: CGFloat = 8
    static let stripPadding = CGSize(width: 8, height: 6)

}

extension Filmstrip {
    /// Whether the Filmstrip is open (View > Show Filmstrip, F6; the `view.showFilmstrip` action).
    static var isVisible: Bool {
        get { UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: visibleKey) }
    }
}

/// One landscape 3:2 thumbnail filled edge to edge with the photo, with the shared ring for
/// focus and selection and the shared corner badges (see ThumbnailCell.swift); dimmed when
/// rejected.
private struct FilmstripCell: View {
    @EnvironmentObject private var model: LibraryModel
    let row: AssetRow
    let index: Int
    let size: CGSize
    let state: ThumbnailState
    let revision: Int
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .opacity(row.flag == .rejected ? ThumbnailState.rejectedOpacity : 1)
            }
            ThumbnailBadges(row: row, size: size, index: index, isFocused: state == .focused)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: ThumbnailState.cornerRadius))
        .thumbnailFrame(state)
        .contentShape(Rectangle())
        .help(ThumbnailBadges.help(for: row))
        .task(id: LoadKey(id: row.id, revision: revision)) { load() }
    }

    private struct LoadKey: Hashable {
        let id: Int64
        let revision: Int
    }

    private func load() {
        let id = row.id
        if let cached = ThumbnailLoader.shared.cached(id) {
            image = cached
        } else if let url = model.thumbnailURL(for: id) {
            ThumbnailLoader.shared.load(id, from: url) { loaded in
                if row.id == id { image = loaded }
            }
        }
    }
}

/// Shows an AppKit menu on right-click or Control-click and lets every other click through
/// to the SwiftUI view underneath.
private struct RightClickMenu: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> MenuView {
        let view = MenuView()
        view.provider = menu
        return view
    }

    func updateNSView(_ nsView: MenuView, context: Context) {
        nsView.provider = menu
    }

    final class MenuView: NSView {
        var provider: (() -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isMenuClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            provider?()
        }

        override func mouseDown(with event: NSEvent) {
            // Control-click: AppKit asks menu(for:) itself only for right clicks.
            guard let menu = provider?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
