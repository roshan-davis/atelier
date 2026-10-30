import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// The Import dialog, laid out like Lightroom's: the photos found in the middle, the settings in
/// panels on the right, a summary and the buttons along the bottom. With Cull before importing
/// it walks through Choose Photos, Cull and Import; otherwise Choose Photos and Import. It is one
/// size on every step and whatever is chosen, so it never jumps, and it stays open until every
/// file is in. The state lives in `ImportFlow`.
struct ImportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @StateObject private var flow: ImportFlow

    /// Big enough for the Cull view, and the same for every step.
    static let size = CGSize(width: 1100, height: 760)

    init(model: LibraryModel) {
        _flow = StateObject(wrappedValue: ImportFlow(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            ImportHeader(flow: flow)
            Divider()
            Group {
                switch flow.step {
                case .choose:
                    ImportChooseStep(flow: flow) { dismiss() }
                case .cull:
                    if let cull = flow.cull {
                        CullView(cull: cull, embedded: true)
                    }
                case .importing:
                    ImportProgressStep(copying: flow.copyFiles, photos: flow.wall) { dismiss() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: theme.panel))
        .onDisappear { flow.closed() }
    }
}

// MARK: - Header

/// The title, what this step is for, and on the right where the user is in the steps. The
/// icon on the left follows the step.
private struct ImportHeader: View {
    @ObservedObject var flow: ImportFlow

    private var steps: [(step: ImportFlow.Step, title: String)] {
        flow.cullFirst ? [(.choose, "Choose Photos"), (.cull, "Cull"), (.importing, "Import")]
            : [(.choose, "Choose Photos"), (.importing, "Import")]
    }

    private var subtitle: String {
        switch flow.step {
        case .choose: return "Pick folders or photos, then how they come in."
        case .cull: return "Keep the best of each group of similar shots."
        case .importing: return flow.copyFiles ? "Copying into your library folder." : "Adding to your catalog."
        }
    }

    private var icon: String {
        switch flow.step {
        case .choose: return "photo.on.rectangle.angled"
        case .cull: return "square.stack.3d.down.right"
        case .importing: return "square.and.arrow.down"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 13))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Photos").font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.body).foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Capsule()
                            .fill(item.step.rawValue <= flow.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 56, height: 2)
                            .padding(.top, 16)
                    }
                    StepDot(number: index + 1, title: item.title,
                            state: item.step == flow.step ? .current : (item.step.rawValue < flow.step.rawValue ? .done : .ahead))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: flow.step)
            .animation(.easeInOut(duration: 0.25), value: flow.cullFirst)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color.primary.opacity(0.04))
    }
}

/// A step: a numbered circle (a check once done) with its name underneath.
private struct StepDot: View {
    enum Phase { case done, current, ahead }
    let number: Int
    let title: String
    let state: Phase

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(state == .ahead ? Color.clear : Color.accentColor)
                Circle()
                    .strokeBorder(state == .ahead ? Color.secondary.opacity(0.5) : Color.accentColor, lineWidth: 2)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(state == .current ? Color.white : Color.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .shadow(color: state == .current ? Color.accentColor.opacity(0.45) : .clear, radius: 6)
            Text(title)
                .font(.callout.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .ahead ? Color.secondary : Color.primary)
                .fixedSize()
        }
        .frame(minWidth: 70)
    }
}

/// The bar along the bottom of every step: a note or summary on the left, buttons on the right.
struct ImportFooter<Leading: View, Buttons: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                leading()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 16)
                buttons()
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Choose Photos

/// Step 1: the photos found on the left (or a drop area), the settings panels on the right.
private struct ImportChooseStep: View {
    @ObservedObject var flow: ImportFlow
    let close: () -> Void
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.theme) private var theme
    @State private var dropTargeted = false
    @AppStorage("import.panels.into") private var intoOpen = true
    @AppStorage("import.panels.files") private var filesOpen = true
    @AppStorage("import.panels.apply") private var applyOpen = true
    @AppStorage("import.panels.cull") private var cullOpen = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sourcePane
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        SidebarSection(title: "Import Into", isExpanded: $intoOpen) { EmptyView() } content: { intoPanel }
                        SidebarSection(title: "File Handling", isExpanded: $filesOpen) { EmptyView() } content: { filesPanel }
                        SidebarSection(title: "Apply During Import", isExpanded: $applyOpen) { EmptyView() } content: { applyPanel }
                        SidebarSection(title: "Culling", isExpanded: $cullOpen) { EmptyView() } content: { cullPanel }
                    }
                }
                .frame(width: 320)
                .background(Color(nsColor: theme.panel))
            }
            ImportFooter {
                Text(summary)
            } buttons: {
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(flow.cullFirst ? "Continue to Cull" : importTitle) { flow.next(close: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canContinue)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            flow.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var importTitle: String {
        let count = flow.photoCount
        return count == 0 ? "Import" : "Import \(count) Photo\(count == 1 ? "" : "s")"
    }

    /// "412 photos · 18.4 GB · copied to 2026/2026-10-30 Beach in Atelier Library".
    private var summary: String {
        guard !flow.sources.isEmpty else { return "No photos chosen yet" }
        if flow.isScanning { return "Looking for photos…" }
        let size = ByteCountFormatter.string(fromByteCount: flow.bytes, countStyle: .file)
        var parts = ["\(flow.photoCount) photo\(flow.photoCount == 1 ? "" : "s")", size]
        if flow.copyFiles {
            parts.append("copied into \(URL(fileURLWithPath: flow.destinationPath).lastPathComponent)")
        } else {
            parts.append("left where they are")
        }
        parts.append("into \u{201C}\(flow.effectiveName)\u{201D}")
        return parts.joined(separator: " · ")
    }

    // MARK: Source pane

    private var sourcePane: some View {
        VStack(spacing: 0) {
            if !flow.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(flow.sources) { source in
                            SourceChip(source: source) { flow.remove(source.url) }
                        }
                        Button(action: choose) {
                            Label("Add…", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add more folders or photos")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                Divider()
            }
            ZStack {
                Color(nsColor: theme.gridBackground)
                if flow.sources.isEmpty {
                    dropZone
                } else if flow.photos.isEmpty {
                    if flow.isScanning {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for photos…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No photos in what you chose").foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 160), spacing: 10)], spacing: 10) {
                            ForEach(flow.photos, id: \.self) { SourceThumbnail(url: $0) }
                        }
                        .padding(14)
                    }
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drag folders or photos here")
                .font(.title3.weight(.semibold))
            Text("A memory card, a folder on this Mac, or one on the NAS")
                .foregroundStyle(.secondary)
            Button("Choose Folders or Photos…", action: choose)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.45))
        )
    }

    // MARK: Panels

    private var intoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Import into", selection: $flow.existingGroup) {
                Text("New import").tag(Int64?.none)
                if !model.sidebar.imports.isEmpty {
                    Divider()
                    ForEach(model.sidebar.imports) { entry in
                        Text("\(entry.name) (\(entry.photoCount))").tag(Int64?.some(entry.id))
                    }
                }
            }
            .labelsHidden()
            if flow.existingGroup == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: Binding(get: { flow.name }, set: { flow.setName($0) }),
                              prompt: Text(flow.suggestedName))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }
        }
        .panelPadding()
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Files", selection: $flow.copyFiles) {
                Text("Leave files where they are").tag(false)
                Text("Copy into my library folder").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if flow.copyFiles {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: flow.destinationPath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(flow.destinationPath)
                    Spacer()
                    Button("Change…", action: chooseDestination)
                        .controlSize(.small)
                }
                Text("Into YYYY/YYYY-MM-DD \(flow.effectiveName)/, each copy checked against the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Photos stay in their folders, on this Mac or the NAS. Nothing is moved or changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelPadding()
    }

    private var applyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Develop settings").font(.caption).foregroundStyle(.secondary)
                Picker("Develop settings", selection: $flow.presetID) {
                    Text("None").tag("")
                    ForEach(presetGroups, id: \.0) { group in
                        Section(group.0) {
                            ForEach(group.1) { preset in
                                Text(preset.name).tag(preset.id.uuidString)
                            }
                        }
                    }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Keywords").font(.caption).foregroundStyle(.secondary)
                TextField("Keywords", text: $flow.keywords, prompt: Text("Comma separated"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
        }
        .panelPadding()
    }

    private var cullPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Cull before importing", isOn: $flow.cullFirst)
                .toggleStyle(.switch)
                .controlSize(.small)
            Text("Groups similar shots and suggests the best of each, so you pick the keepers first. The rest are cataloged as Rejected, to look at again later with Photo > Show Cull Group.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelPadding()
    }

    /// The presets by group, as in the Presets panel, keeping a hidden pack's preset if it is the
    /// one already chosen.
    private var presetGroups: [(String, [DevelopPreset])] {
        var result: [(String, [DevelopPreset])] = []
        for preset in model.develop.presets
        where model.develop.visiblePresets.contains(preset) || preset.id.uuidString == flow.presetID {
            if let index = result.firstIndex(where: { $0.0 == preset.group }) {
                result[index].1.append(preset)
            } else {
                result.append((preset.group, [preset]))
            }
        }
        return result
    }

    // MARK: Pickers

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = "Add"
        panel.message = "Choose folders or photos to import"
        if panel.runModal() == .OK { flow.add(panel.urls) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            flow.destinationPath = url.path
        }
    }
}

private extension View {
    func panelPadding() -> some View {
        padding(.horizontal, 6).padding(.vertical, 2)
    }
}

/// A chosen folder or file: its name, how many photos, and a button to take it out.
private struct SourceChip: View {
    let source: ImportFlow.Source
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source.url.hasDirectoryPath ? "folder.fill" : "photo")
                .foregroundStyle(Color.accentColor)
            Text(source.url.lastPathComponent)
                .lineLimit(1)
            if let photos = source.photos {
                Text("\(photos.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.55)
            .help("Remove from this import")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(hovering ? 0.1 : 0.06), in: Capsule())
        .onHover { hovering = $0 }
        .help(source.url.path)
    }
}

/// A photo about to be imported, from its embedded preview, decoded off the main thread.
private struct SourceThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.2))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
            }
            .aspectRatio(1.3, contentMode: .fit)
            Text(url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: url) { image = await Self.load(url) }
    }

    /// The photo's embedded preview, small, from the cache or read off the main thread.
    static func load(_ url: URL, priority: TaskPriority = .utility) async -> NSImage? {
        if let cached = SourceThumbnailCache.shared.object(forKey: url as NSURL) { return cached }
        let loaded = await Task.detached(priority: priority) {
            Culling.image(at: url, maxPixel: 320).map { NSImage(cgImage: $0, size: .zero) }
        }.value
        if let loaded { SourceThumbnailCache.shared.setObject(loaded, forKey: url as NSURL) }
        return loaded
    }
}

private enum SourceThumbnailCache {
    static let shared: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 2000
        return cache
    }()
}

// MARK: - Importing

/// The last step: how far the import has got, in big clear figures, with Cancel, over a wall
/// of the photos being imported that light up as each one is in. Run in Background closes the
/// dialog and leaves the progress in the status bar. The dialog closes by itself when every
/// file is in.
struct ImportProgressStep: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.theme) private var theme
    let copying: Bool
    var photos: [ImportWallPhoto] = []
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: theme.gridBackground)
                ImportWall(photos: photos, done: model.importProgress?.doneFiles ?? [])
                // The wall recedes behind the card, so the figures stay easy to read.
                RadialGradient(colors: [Color(nsColor: theme.gridBackground).opacity(0.92),
                                        Color(nsColor: theme.gridBackground).opacity(0.15)],
                               center: .center, startRadius: 180, endRadius: 640)
                    .allowsHitTesting(false)
                VStack(spacing: 22) {
                    if let progress = model.importProgress {
                        figures(progress)
                    } else {
                        ProgressView()
                    }
                }
                .padding(32)
                .frame(width: 560)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.2)))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            }
            ImportFooter {
                Text(copying ? "Each copy is checked against the original. Thumbnails are made once every photo is in."
                     : "Thumbnails are made once every photo is in.")
            } buttons: {
                Button("Run in Background", action: close)
                    .help("Close this dialog; the progress stays in the status bar")
                Button("Cancel Import", role: .cancel) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.importProgress?.phase == "Cancelling…")
            }
        }
        .onChange(of: model.importProgress == nil) { _, finished in
            if finished { close() }
        }
        .onAppear {
            if model.importProgress == nil { close() }
        }
    }

    @ViewBuilder
    private func figures(_ progress: ImportStatus) -> some View {
        VStack(spacing: 6) {
            if let done = progress.done, let total = progress.total, total > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(done)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(total) photo\(total == 1 ? "" : "s") \(copying ? "copied" : "added")")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(progress.phase).font(.title2.weight(.semibold))
            }
        }
        VStack(spacing: 8) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.large)
                    .animation(.easeOut(duration: 0.25), value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.large)
            }
            Text(progress.file ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 0) {
            figure(copying ? "Copied" : "Read", progress.amount ?? "–")
            Divider().frame(height: 34)
            figure("Speed", progress.speed ?? "–")
            Divider().frame(height: 34)
            figure("Time left", progress.timeLeft ?? "Working it out…")
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Behind the copy step's figures: every photo being imported, faint and grey until it is in
/// the catalog, then in full color with a check. The wall moves on by itself to keep the photos
/// being copied in view. Thumbnails come from the Cull step, or the Choose step's cache, so the
/// wall adds almost nothing to the copy.
private struct ImportWall: View {
    let photos: [ImportWallPhoto]
    let done: Set<String>
    @State private var position = ScrollPosition(edge: .top)
    @State private var size: CGSize = .zero

    private static let spacing = 6.0
    private static let padding = 12.0
    /// The tile width aimed for; tiles stretch a little to fill the width.
    private static let target = 128.0

    var body: some View {
        let layout = Layout(width: size.width, count: photos.count)
        ScrollView(.vertical, showsIndicators: false) {
            if layout.tile > 0 {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.tile), spacing: Self.spacing),
                                         count: layout.columns),
                          spacing: Self.spacing) {
                    ForEach(photos) { photo in
                        ImportWallTile(photo: photo, isDone: done.contains(photo.key))
                            .frame(width: layout.tile, height: layout.tileHeight)
                    }
                }
                .padding(Self.padding)
            }
        }
        .scrollDisabled(true)
        .scrollPosition($position)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onChange(of: firstWaiting) { _, index in follow(index, layout) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The first photo not in yet: copies finish a few at a time, a little out of order.
    private var firstWaiting: Int {
        photos.firstIndex { !done.contains($0.key) } ?? photos.count
    }

    /// Keeps the row being copied a little above the middle, where the card doesn't hide it all.
    private func follow(_ index: Int, _ layout: Layout) {
        guard layout.tile > 0, size.height > 0 else { return }
        let row = Double(min(index, max(photos.count - 1, 0)) / layout.columns)
        let rowStride = layout.tileHeight + Self.spacing
        let content = Self.padding * 2 + Double(layout.rows) * rowStride - Self.spacing
        let y = Self.padding + row * rowStride - size.height * 0.3
        let clamped = min(max(0, content - size.height), max(0, y))
        withAnimation(.easeInOut(duration: 0.8)) { position.scrollTo(y: clamped) }
    }

    private struct Layout {
        let columns: Int
        let tile: Double
        let rows: Int
        var tileHeight: Double { (tile * 0.75).rounded() }

        init(width: Double, count: Int) {
            let usable = width - ImportWall.padding * 2
            columns = max(1, Int((usable + ImportWall.spacing) / (ImportWall.target + ImportWall.spacing)))
            tile = usable > 40 ? ((usable - Double(columns - 1) * ImportWall.spacing) / Double(columns)).rounded(.down) : 0
            rows = (count + columns - 1) / columns
        }
    }
}

private struct ImportWallTile: View {
    let photo: ImportWallPhoto
    let isDone: Bool
    @State private var loaded: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
            if let image = photo.thumbnail ?? loaded {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.system(size: 15))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .padding(5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .saturation(isDone ? 1 : 0)
        .opacity(isDone ? 1 : 0.32)
        .animation(.easeOut(duration: 0.4), value: isDone)
        .task(id: photo.url) {
            // Only for photos the Cull step didn't show: a small read of the embedded preview,
            // at low priority so the copy keeps the drive.
            if photo.thumbnail == nil { loaded = await SourceThumbnail.load(photo.url, priority: .background) }
        }
    }
}
