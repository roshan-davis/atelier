import AppKit
import ImageIO
import AtelierCore
import SwiftUI

/// The library grid. NSCollectionView rather than SwiftUI so 100k cells scroll smoothly.
struct GridView: NSViewRepresentable {
    @ObservedObject var model: LibraryModel
    var background: NSColor = .windowBackgroundColor
    /// The thumbnail size slider in the filter bar.
    @AppStorage(GridThumbnails.sizeKey) private var thumbnailSize = GridThumbnails.defaultSize

    init(model: LibraryModel, background: NSColor = .windowBackgroundColor) {
        self.model = model
        self.background = background
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = GridThumbnails.itemSize(for: thumbnailSize)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collectionView = GridCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [background]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.onDoubleClick = { [weak model] in model?.openLoupe() }
        collectionView.menuForItem = { [weak coordinator = context.coordinator] index in
            coordinator?.menu(forItemAt: index)
        }
        context.coordinator.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        // Come back to the same place: after switching views, and after a relaunch.
        context.coordinator.pendingTopID = model.gridTopID
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        context.coordinator.update(rows: model.rows, selection: model.selection, focusedID: model.focusedID,
                                   revision: model.previewRevision)
        Task { @MainActor in collectionView.window?.makeFirstResponder(collectionView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let collectionView = context.coordinator.collectionView, collectionView.backgroundColors != [background] {
            collectionView.backgroundColors = [background]
        }
        if let collectionView = context.coordinator.collectionView,
           let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout,
           layout.itemSize != GridThumbnails.itemSize(for: thumbnailSize) {
            layout.itemSize = GridThumbnails.itemSize(for: thumbnailSize)
            context.coordinator.refreshVisibleItems()
        }
        context.coordinator.update(rows: model.rows, selection: model.selection, focusedID: model.focusedID,
                                   revision: model.previewRevision)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: LibraryModel
        weak var collectionView: NSCollectionView?
        private var rows: [AssetRow] = []
        private var indexByID: [Int64: Int] = [:]
        private var revision = -1
        private var focusedID: Int64?
        private var applyingSelection = false
        /// The photo to scroll to the top once it is in the grid.
        var pendingTopID: Int64?

        init(model: LibraryModel) {
            self.model = model
        }

        func update(rows newRows: [AssetRow], selection: Set<Int64>, focusedID newFocusedID: Int64?, revision newRevision: Int) {
            guard let collectionView else { return }
            focusedID = newFocusedID
            if newRows.map(\.id) != rows.map(\.id) {
                rows = newRows
                indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
                collectionView.reloadData()
            } else if newRows != rows || newRevision != revision {
                // Same photos, changed ratings or previews: refresh visible cells in place.
                rows = newRows
                refreshVisibleItems()
            } else {
                // The focused photo may have moved within the selection.
                for indexPath in collectionView.indexPathsForVisibleItems() {
                    (collectionView.item(at: indexPath) as? ThumbnailItem)?.isFocused = rows[indexPath.item].id == focusedID
                }
            }
            revision = newRevision
            if let id = pendingTopID, let index = indexByID[id] {
                collectionView.layoutSubtreeIfNeeded()
                collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .top)
                pendingTopID = nil
            }

            let wanted = Set(selection.compactMap { indexByID[$0] }.map { IndexPath(item: $0, section: 0) })
            if wanted != collectionView.selectionIndexPaths {
                applyingSelection = true
                collectionView.selectionIndexPaths = wanted
                applyingSelection = false
                // Scroll only when the focused photo is not fully in view, as the Filmstrip does.
                if let focused = model.focusedID, let index = indexByID[focused] {
                    let indexPath = IndexPath(item: index, section: 0)
                    let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
                    if frame.map({ !collectionView.visibleRect.contains($0) }) ?? true {
                        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
                    }
                }
            }
        }

        /// Reconfigures the cells on screen: new ratings, previews or thumbnail size.
        func refreshVisibleItems() {
            guard let collectionView else { return }
            for indexPath in collectionView.indexPathsForVisibleItems() where rows.indices.contains(indexPath.item) {
                configure(collectionView.item(at: indexPath) as? ThumbnailItem, at: indexPath.item)
            }
        }

        private func configure(_ item: ThumbnailItem?, at index: Int) {
            guard let item, let collectionView else { return }
            let width = (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize.width
                ?? CGFloat(GridThumbnails.defaultSize)
            item.configure(with: rows[index], model: model, badgeWidth: width - 2 * ThumbnailItem.inset)
            item.isFocused = rows[index].id == focusedID
        }

        @objc func didScroll() {
            guard pendingTopID == nil, let collectionView,
                  let top = collectionView.indexPathsForVisibleItems().min(), rows.indices.contains(top.item)
            else { return }
            let id = rows[top.item].id
            // Defer: scrolling can happen during a SwiftUI view update.
            Task { @MainActor [model] in model.gridScrolled(toTop: id) }
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            rows.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
            configure(item as? ThumbnailItem, at: indexPath.item)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection(focus: indexPaths.max()?.item)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection(focus: nil)
        }

        /// Right-click: select the photo under the pointer (unless it is already selected).
        func menu(forItemAt index: Int) -> NSMenu? {
            guard let collectionView, rows.indices.contains(index) else { return nil }
            let id = rows[index].id
            let indexPath = IndexPath(item: index, section: 0)
            if !collectionView.selectionIndexPaths.contains(indexPath) {
                applyingSelection = true
                collectionView.selectionIndexPaths = [indexPath]
                applyingSelection = false
            }
            model.prepareContextMenu(for: id)
            return model.photoMenu(includeZoom: false)
        }

        private func pushSelection(focus: Int?) {
            guard !applyingSelection, let collectionView else { return }
            let ids = Set(collectionView.selectionIndexPaths.map { rows[$0.item].id })
            let focusID = focus.map { rows[$0].id }
            // Defer: these callbacks can fire during a SwiftUI view update.
            Task { @MainActor [model] in
                model.selection = ids
                if let focusID {
                    model.focusedID = focusID
                } else if let current = model.focusedID, !ids.contains(current) {
                    model.focusedID = ids.first
                }
            }
        }
    }
}

final class GridCollectionView: NSCollectionView {
    var onDoubleClick: (() -> Void)?
    var menuForItem: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return menuForItem?(indexPath.item)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

// MARK: - Cell

/// The grid's thumbnail size, set with the slider in the filter bar.
enum GridThumbnails {
    static let sizeKey = "grid.thumbnailSize"
    static let defaultSize = 176.0
    static let sizeRange = 120.0...320.0

    /// A cell: the square-ish photo area plus the file name under it.
    static func itemSize(for size: Double) -> NSSize {
        let width = min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
        return NSSize(width: width, height: width + 20)
    }
}

/// A grid cell: the photo with the shared corner badges (`ThumbnailBadges`) and the shared ring
/// for focus and selection (`ThumbnailState`), and the file name under it.
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    /// Space between the cell's edge and the photo.
    static let inset: CGFloat = 8

    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badges = PassthroughHostingView(rootView: GridBadges())
    /// The focused photo's white line inside its ring.
    private let keyline = NSView()
    private var assetID: Int64?

    /// The photo being worked on (the Library's focused photo).
    var isFocused = false {
        didSet { if isFocused != oldValue { updateSelectionAppearance() } }
    }

    override func loadView() {
        let container = AppearanceAwareView()
        container.onAppearanceChange = { [weak self] in self?.updateSelectionAppearance() }
        container.wantsLayer = true
        container.layer?.cornerRadius = ThumbnailState.cornerRadius

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        badges.sizingOptions = []
        keyline.wantsLayer = true
        keyline.layer?.borderWidth = 1
        keyline.layer?.cornerRadius = ThumbnailState.cornerRadius - ThumbnailState.focused.borderWidth
        keyline.isHidden = true

        for view in [thumbnailView, badges, nameLabel, keyline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let inset = Self.inset
        let ring = ThumbnailState.focused.borderWidth
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            thumbnailView.bottomAnchor.constraint(equalTo: nameLabel.topAnchor, constant: -4),

            badges.topAnchor.constraint(equalTo: thumbnailView.topAnchor),
            badges.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor),
            badges.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            badges.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            nameLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),

            keyline.topAnchor.constraint(equalTo: container.topAnchor, constant: ring),
            keyline.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ring),
            keyline.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ring),
            keyline.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -ring),
        ])
        view = container
        updateSelectionAppearance()
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    @MainActor
    func configure(with row: AssetRow, model: LibraryModel, badgeWidth: CGFloat) {
        let changedPhoto = assetID != row.id
        if changedPhoto, let previous = assetID, thumbnailView.image == nil {
            model.cancelThumbnail(for: previous)
        }
        assetID = row.id
        nameLabel.stringValue = row.filename
        badges.rootView = GridBadges(row: row, width: badgeWidth)
        view.toolTip = ThumbnailBadges.help(for: row)
        thumbnailView.alphaValue = row.flag == .rejected ? ThumbnailState.rejectedOpacity : 1
        if changedPhoto { thumbnailView.image = nil }

        let id = row.id
        if let image = ThumbnailLoader.shared.cached(id) {
            thumbnailView.image = image
        } else if let url = model.thumbnailURL(for: id) {
            ThumbnailLoader.shared.load(id, from: url) { [weak self] image in
                guard self?.assetID == id else { return }
                self?.thumbnailView.image = image
            }
        }
    }

    private func updateSelectionAppearance() {
        guard isViewLoaded else { return }
        let state = ThumbnailState(isFocused: isFocused, isSelected: isSelected)
        // Layers take fixed colors: resolve the dynamic ones for this cell's appearance.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = state.fill.cgColor
            view.layer?.borderColor = state.borderColor.cgColor
            keyline.layer?.borderColor = ThumbnailState.keyline.cgColor
        }
        view.layer?.borderWidth = state.borderWidth
        keyline.isHidden = state != .focused
        nameLabel.textColor = state == .unselected ? .secondaryLabelColor : .labelColor
        nameLabel.font = .systemFont(ofSize: 11, weight: state == .focused ? .semibold : .regular)
    }

    static func color(for label: ColorLabel) -> NSColor {
        switch label {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        }
    }
}

/// The grid cell's badges, empty until the cell shows a photo.
struct GridBadges: View {
    var row: AssetRow?
    var width: CGFloat = 0

    var body: some View {
        if let row { ThumbnailBadges(row: row, size: CGSize(width: width, height: width)) }
    }
}

/// Tells its owner when light or dark mode changes, so layer colors can be resolved again.
final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Draws SwiftUI over an AppKit view without taking its clicks.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Decodes thumbnails off the main thread and keeps recent ones in memory. NSCache is thread-safe.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSNumber, NSImage>()
    private let queue = DispatchQueue(label: "atelier.thumbnails", qos: .userInitiated, attributes: .concurrent)

    init() {
        cache.countLimit = 4000
    }

    func invalidate(_ id: Int64) {
        cache.removeObject(forKey: NSNumber(value: id))
    }

    func cached(_ id: Int64) -> NSImage? {
        cache.object(forKey: NSNumber(value: id))
    }

    /// Decodes fully off the main thread; NSImage(contentsOf:) would defer decoding to the first draw.
    static func decode(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func load(_ id: Int64, from url: URL, completion: @escaping @MainActor (NSImage?) -> Void) {
        queue.async {
            let image = Self.decode(url)
            if let image { self.cache.setObject(image, forKey: NSNumber(value: id)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(image) }
            }
        }
    }
}
