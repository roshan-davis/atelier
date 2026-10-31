import AppKit
import AtelierCore
import SwiftUI

/// The Filmstrip's header: the source pop-up and where the current photo sits on the left, the
/// Filter and Sort pop-ups on the right. Source, filter and order are the Library's own, so the
/// grid follows every change made here.
struct FilmstripHeader: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.theme) private var theme

    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            sourceButton
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1, height: 12)
            position
                .layoutPriority(-1)
            Spacer(minLength: 8)
            filterButton
            sortButtons
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: Source

    private var sourceButton: some View {
        PopUpMenuButton(menu: { model.filmstripSourceMenu() }) {
            HStack(spacing: 5) {
                Image(systemName: model.sourceSymbol)
                    .foregroundStyle(.secondary)
                Text(model.sourceTitle)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("(\(model.rows.count))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .help("Choose the photos to show: All Photographs, a recent import, a collection or a folder")
    }

    /// "3 selected · 2 of 12 · DSC_0101.NEF · Copy 1".
    private var position: some View {
        HStack(spacing: 6) {
            if model.selection.count > 1 {
                Text("\(model.selection.count) selected")
                    .foregroundStyle(Color.accentColor)
                Text("·").foregroundStyle(.tertiary)
            }
            if let id = model.focusedID, let index = model.rows.firstIndex(where: { $0.id == id }) {
                Text("\(index + 1) of \(model.rows.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                let name = model.rows[index].filename + (model.virtualCopyName(id).map { " · \($0)" } ?? "")
                Text(name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
            }
        }
        .lineLimit(1)
    }

    // MARK: Filter and sort

    private var filterButton: some View {
        let summary = model.filter.summary
        return HStack(spacing: 0) {
            PopUpMenuButton(menu: { model.filmstripFilterMenu() }) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    if summary.isEmpty {
                        Text("Filters")
                    } else {
                        Text("Filters:").foregroundStyle(.secondary)
                        Text(summary.joined(separator: " · "))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 240)
                .fixedSize(horizontal: false, vertical: true)
            }
            .help(summary.isEmpty ? "Show only some photos: by flag, rating, color label or edits"
                                  : "Filters: \(summary.joined(separator: ", "))")
            if !summary.isEmpty {
                Button {
                    model.filter = model.filter.cleared
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                }
                .buttonStyle(.plain)
                .help("Clear filters and show every photo in this source")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(summary.isEmpty ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private var sortButtons: some View {
        HStack(spacing: 4) {
            PopUpMenuButton(menu: { model.filmstripSortMenu() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                    Text("Sort:").foregroundStyle(.secondary)
                    Text(model.filter.sort.title).fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            .help("Sort photos by capture time, import order, file name, rating or edit time")
            Button {
                model.filter.ascending.toggle()
            } label: {
                Image(systemName: model.filter.ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.filter.ascending ? "Ascending: oldest, A to Z, fewest stars first. Click for descending."
                                         : "Descending: newest, Z to A, most stars first. Click for ascending.")
        }
    }
}

// MARK: - Menus

extension LibraryModel {
    /// The current source's name, as in the sidebar.
    var sourceTitle: String {
        switch sidebarSelection ?? .all {
        case .all: return "All Photographs"
        case .volume(let id): return sidebar.volumes.first { $0.id == id }?.name ?? "Volume"
        case .folder(let id):
            guard let folder = sidebar.folders.first(where: { $0.id == id }) else { return "Folder" }
            return folder.relativePath.isEmpty ? "/" : (folder.relativePath as NSString).lastPathComponent
        case .collection(let id): return sidebar.collections.first { $0.id == id }?.name ?? "Collection"
        case .importGroup(let id): return sidebar.imports.first { $0.id == id }?.name ?? "Import"
        }
    }

    var sourceSymbol: String {
        Self.symbol(for: sidebarSelection ?? .all)
    }

    static func symbol(for source: SidebarItem) -> String {
        switch source {
        case .all: return "photo.on.rectangle"
        case .volume: return "externaldrive"
        case .folder: return "folder"
        case .collection: return "rectangle.stack"
        case .importGroup: return "tray.and.arrow.down"
        }
    }

    /// How many recent imports the Filmstrip's source menu lists.
    static let recentImportCount = 8

    /// The Filmstrip's source pop-up, as Lightroom Classic's: All Photographs, the most recent
    /// imports, collections, then each drive's folders. Choosing one changes the Library source
    /// and keeps the current module.
    func filmstripSourceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = sidebarSelection ?? .all
        func item(_ title: String, _ source: SidebarItem, count: Int? = nil) -> NSMenuItem {
            let menuItem = ClosureMenuItem(count.map { "\(title)  (\($0))" } ?? title, checked: current == source) {
                self.sidebarSelection = source
            }
            menuItem.image = NSImage(systemSymbolName: Self.symbol(for: source), accessibilityDescription: nil)
            return menuItem
        }

        menu.addItem(item("All Photographs", .all, count: sidebar.totalCount))

        let imports = sidebar.imports.sorted { $0.createdAt > $1.createdAt }.prefix(Self.recentImportCount)
        if !imports.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recent Imports"))
            for group in imports { menu.addItem(item(group.name, .importGroup(group.id), count: group.photoCount)) }
        }

        let collections = sidebar.collections.filter { !$0.isSet }
        if !collections.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Collections"))
            for collection in collections {
                if let id = collection.id { menu.addItem(item(collection.name, .collection(id))) }
            }
        }

        if !sidebar.volumes.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Folders"))
            for volume in sidebar.volumes {
                guard let volumeID = volume.id else { continue }
                let folders = NSMenu()
                folders.autoenablesItems = false
                folders.addItem(item("All Photos on \(volume.name)", .volume(volumeID)))
                folders.addItem(.separator())
                for folder in sidebar.folders where folder.volumeId == volumeID {
                    if let id = folder.id { folders.addItem(item(folder.displayName, .folder(id))) }
                }
                let entry = NSMenuItem(title: volume.isOnline ? volume.name : "\(volume.name) (offline)",
                                       action: nil, keyEquivalent: "")
                entry.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
                // A check on the drive when the source is it or one of its folders.
                switch current {
                case .volume(let id) where id == volumeID: entry.state = .on
                case .folder(let id) where sidebar.folders.contains(where: { $0.id == id && $0.volumeId == volumeID }):
                    entry.state = .mixed
                default: break
                }
                entry.submenu = folders
                menu.addItem(entry)
            }
        }
        return menu
    }

    /// The Filmstrip's Filter pop-up: the same rules as the Library filter bar.
    func filmstripFilterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func section<Value: Equatable>(_ title: String, _ path: WritableKeyPath<LibraryFilter, Value>,
                                       _ choices: [(String, Value)]) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            for (name, value) in choices {
                menu.addItem(ClosureMenuItem(name, checked: filter[keyPath: path] == value) {
                    self.filter[keyPath: path] = value
                })
            }
        }
        let flags: [(String, Flag?)] = [("Any Flag", nil), ("Picked", .picked), ("Unflagged", Flag.none), ("Rejected", .rejected)]
        section("Flag", \.flag, flags)
        var ratings: [(String, Int)] = [("Any Rating", 0)]
        for stars in 1...5 { ratings.append((String(repeating: "★", count: stars) + " and Higher", stars)) }
        section("Rating", \.minRating, ratings)
        var labels: [(String, ColorLabel?)] = [("Any Label", nil)]
        for label in ColorLabel.allCases { labels.append((label.rawValue, label)) }
        section("Color Label", \.colorLabel, labels)
        let edits: [(String, Bool?)] = [("Edited or Not", nil), ("Edited", true), ("Unedited", false)]
        section("Edits", \.edited, edits)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Clear Filters", enabled: filter.isFiltering) { self.filter = self.filter.cleared })
        return menu
    }

    /// The Filmstrip's Sort pop-up: the key, then the direction.
    func filmstripSortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for sort in LibrarySort.allCases {
            menu.addItem(ClosureMenuItem(sort.title, checked: filter.sort == sort) { self.filter.sort = sort })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Ascending", checked: filter.ascending) { self.filter.ascending = true })
        menu.addItem(ClosureMenuItem("Descending", checked: !filter.ascending) { self.filter.ascending = false })
        return menu
    }
}

// MARK: - Pop-up button

/// A plain button that opens an AppKit menu just under itself, like a pop-up button, with any
/// SwiftUI label.
struct PopUpMenuButton<Label: View>: View {
    let menu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.show(menu())
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
    }
}

/// Where a `PopUpMenuButton`'s menu opens: the button's own AppKit view.
@MainActor
final class MenuAnchor {
    weak var view: NSView?

    func show(_ menu: NSMenu) {
        guard let view else { return }
        // Not flipped: y 0 is the bottom edge, so the menu's top sits just below the button.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
