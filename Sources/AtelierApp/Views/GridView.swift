import AppKit
import ImageIO
import AtelierCore
import SwiftUI

/// The library grid. NSCollectionView rather than SwiftUI so 100k cells scroll smoothly.
struct GridView: NSViewRepresentable {
    @ObservedObject var model: LibraryModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 176, height: 196)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collectionView = GridCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.windowBackgroundColor]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.onDoubleClick = { [weak model] in model?.openLoupe() }
        context.coordinator.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        context.coordinator.update(rows: model.rows, selection: model.selection, revision: model.previewRevision)
        Task { @MainActor in collectionView.window?.makeFirstResponder(collectionView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(rows: model.rows, selection: model.selection, revision: model.previewRevision)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: LibraryModel
        weak var collectionView: NSCollectionView?
        private var rows: [AssetRow] = []
        private var indexByID: [Int64: Int] = [:]
        private var revision = -1
        private var applyingSelection = false

        init(model: LibraryModel) {
            self.model = model
        }

        func update(rows newRows: [AssetRow], selection: Set<Int64>, revision newRevision: Int) {
            guard let collectionView else { return }
            if newRows.map(\.id) != rows.map(\.id) {
                rows = newRows
                indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
                collectionView.reloadData()
            } else if newRows != rows || newRevision != revision {
                // Same photos, changed ratings or previews: refresh visible cells in place.
                rows = newRows
                for indexPath in collectionView.indexPathsForVisibleItems() {
                    (collectionView.item(at: indexPath) as? ThumbnailItem)?
                        .configure(with: rows[indexPath.item], model: model)
                }
            }
            revision = newRevision

            let wanted = Set(selection.compactMap { indexByID[$0] }.map { IndexPath(item: $0, section: 0) })
            if wanted != collectionView.selectionIndexPaths {
                applyingSelection = true
                collectionView.selectionIndexPaths = wanted
                applyingSelection = false
                if let focused = model.focusedID, let index = indexByID[focused] {
                    collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)],
                                                 scrollPosition: .nearestHorizontalEdge)
                }
            }
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            rows.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
            (item as? ThumbnailItem)?.configure(with: rows[indexPath.item], model: model)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection(focus: indexPaths.max()?.item)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection(focus: nil)
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

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

// MARK: - Cell

final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let labelStrip = NSView()
    private var assetID: Int64?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        badgeLabel.font = .systemFont(ofSize: 11)
        badgeLabel.textColor = .labelColor
        labelStrip.wantsLayer = true
        labelStrip.layer?.cornerRadius = 2

        for view in [thumbnailView, nameLabel, badgeLabel, labelStrip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            thumbnailView.heightAnchor.constraint(equalToConstant: 140),

            badgeLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 6),
            badgeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            labelStrip.centerYAnchor.constraint(equalTo: badgeLabel.centerYAnchor),
            labelStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            labelStrip.widthAnchor.constraint(equalToConstant: 14),
            labelStrip.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.topAnchor.constraint(equalTo: badgeLabel.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])
        view = container
        updateSelectionAppearance()
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    @MainActor
    func configure(with row: AssetRow, model: LibraryModel) {
        let changedPhoto = assetID != row.id
        if changedPhoto, let previous = assetID, thumbnailView.image == nil {
            model.cancelThumbnail(for: previous)
        }
        assetID = row.id
        nameLabel.stringValue = row.filename
        badgeLabel.stringValue = Self.badge(for: row)
        labelStrip.layer?.backgroundColor = row.colorLabel.map { Self.color(for: $0).cgColor }
        labelStrip.isHidden = row.colorLabel == nil
        thumbnailView.alphaValue = row.flag == .rejected ? 0.35 : 1
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
        view.layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
    }

    static func badge(for row: AssetRow) -> String {
        let stars = row.rating > 0 ? String(repeating: "★", count: row.rating) : ""
        let flag: String
        switch row.flag {
        case .picked: flag = "⚑ "
        case .rejected: flag = "✕ "
        case .none: flag = ""
        }
        return flag + stars
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

/// Decodes thumbnails off the main thread and keeps recent ones in memory. NSCache is thread-safe.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSNumber, NSImage>()
    private let queue = DispatchQueue(label: "atelier.thumbnails", qos: .userInitiated, attributes: .concurrent)

    init() {
        cache.countLimit = 4000
    }

    func cached(_ id: Int64) -> NSImage? {
        cache.object(forKey: NSNumber(value: id))
    }

    /// Decodes fully off the main thread; NSImage(contentsOf:) would defer decoding to the first draw.
    private static func decode(_ url: URL) -> NSImage? {
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
