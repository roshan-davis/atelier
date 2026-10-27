import AppKit
import AtelierCore
import SwiftUI

/// Lightroom's Filmstrip: the photos of the current source in a strip along the bottom, with
/// the photo being worked on highlighted. The arrow tab on the bottom edge (or View > Show
/// Filmstrip, F6) collapses and opens it; the top edge drags to resize. Both are remembered.
struct FilmstripView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.theme) private var theme
    @AppStorage(Filmstrip.visibleKey) private var isVisible = true
    @AppStorage(Filmstrip.heightKey) private var height = Filmstrip.defaultHeight
    @State private var startHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                resizeEdge
                header
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
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startHeight ?? height
                            startHeight = start
                            height = min(Filmstrip.maxHeight, max(Filmstrip.minHeight, start - value.translation.height))
                        }
                        .onEnded { _ in startHeight = nil })
            )
            .help("Drag to resize the Filmstrip")
    }

    /// Source, count and where the current photo sits, like Lightroom's Filmstrip header.
    private var header: some View {
        HStack(spacing: 6) {
            Text(sourceTitle).fontWeight(.semibold)
            Text("·")
            Text("\(model.rows.count) photo\(model.rows.count == 1 ? "" : "s")")
            if model.selection.count > 1 {
                Text("· \(model.selection.count) selected")
            }
            if let id = model.focusedID, let index = model.rows.firstIndex(where: { $0.id == id }) {
                Text("·")
                Text("\(index + 1) of \(model.rows.count)")
                Text("·").foregroundStyle(.tertiary)
                Text(model.rows[index].filename + (model.virtualCopyName(id).map { " · \($0)" } ?? ""))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private var strip: some View {
        GeometryReader { geometry in
            let cell = max(40, geometry.size.height - 10)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 4) {
                        ForEach(model.rows) { row in
                            FilmstripCell(row: row, size: cell,
                                          isFocused: model.focusedID == row.id,
                                          isSelected: model.selection.contains(row.id),
                                          revision: model.previewRevision)
                                .id(row.id)
                                .onTapGesture(count: 2) {
                                    model.selection = [row.id]
                                    model.focusedID = row.id
                                    if model.mode == .grid { model.openLoupe() }
                                }
                                .onTapGesture { select(row.id) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onAppear { if let id = model.focusedID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.focusedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Color(nsColor: theme.gridBackground))
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

    private var sourceTitle: String {
        let sidebar = model.sidebar
        switch model.sidebarSelection ?? .all {
        case .all: return "All Photographs"
        case .volume(let id): return sidebar.volumes.first { $0.id == id }?.name ?? "Volume"
        case .folder(let id):
            guard let folder = sidebar.folders.first(where: { $0.id == id }) else { return "Folder" }
            return folder.relativePath.isEmpty ? "/" : (folder.relativePath as NSString).lastPathComponent
        case .collection(let id): return sidebar.collections.first { $0.id == id }?.name ?? "Collection"
        case .importGroup(let id): return sidebar.imports.first { $0.id == id }?.name ?? "Import"
        }
    }
}

enum Filmstrip {
    static let visibleKey = "filmstrip.visible"
    static let heightKey = "filmstrip.height"
    static let defaultHeight = 92.0
    static let minHeight = 56.0
    static let maxHeight = 220.0

}

/// View > Show Filmstrip (F6), checked while the Filmstrip is open.
struct FilmstripMenuItem: View {
    @AppStorage(Filmstrip.visibleKey) private var isVisible = true

    var body: some View {
        Toggle("Show Filmstrip", isOn: $isVisible)
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [])
    }
}

/// One square thumbnail: a bright border on the photo being worked on, a softer one on the
/// rest of the selection, dimmed when rejected, with stars, flag and stack badges.
private struct FilmstripCell: View {
    @EnvironmentObject private var model: LibraryModel
    let row: AssetRow
    let size: CGFloat
    let isFocused: Bool
    let isSelected: Bool
    let revision: Int
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(isSelected ? 0.9 : 0.35))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                    .opacity(row.flag == .rejected ? 0.35 : 1)
            }
        }
        .overlay(alignment: .bottomLeading) {
            let badge = ThumbnailItem.badge(for: row).trimmingCharacters(in: .whitespaces)
            if !badge.isEmpty, size >= 64 {
                Text(badge)
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.bottom, 3)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isFocused ? Color.primary : (isSelected ? Color.primary.opacity(0.4) : .clear),
                              lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(Rectangle())
        .help(row.filename)
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
