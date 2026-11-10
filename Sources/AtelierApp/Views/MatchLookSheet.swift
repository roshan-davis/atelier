import AppKit
import AtelierCore
import SwiftUI
import UniformTypeIdentifiers

/// Photo > Match Look to Reference…: pick a reference, preview the matched photo next to it, and
/// apply the result as ordinary Develop settings. Nothing changes on the photo until Apply.
struct MatchLookSheet: View {
    @ObservedObject var match: MatchLookModel
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingBefore = false
    @State private var choosingCatalogPhoto = false
    @State private var choosingBuiltIn = false
    @State private var dropTargeted = false
    @State private var showingDifferences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Match Look").font(.title2.bold())
                Spacer()
                Text(match.otherCount > 0 ? "\(match.photoName) and \(match.otherCount) more" : match.photoName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    paneTitle("Reference", detail: match.referenceName)
                    referenceImage
                    referenceButtons
                    recentRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    paneTitle(showingBefore ? "Before" : "Your Photo", detail: nil)
                    photoImage
                    HStack {
                        Label("Hold to See Before", systemImage: "eye")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(showingBefore ? 0.2 : 0.08)))
                            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, perform: {},
                                                onPressingChanged: { showingBefore = $0 })
                            .help("Press and hold to see the photo before the match")
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            controls
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 900, height: 660)
    }

    private func paneTitle(_ title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: Reference

    @ViewBuilder private var referenceImage: some View {
        ZStack {
            if let image = match.referenceImage {
                AreaImage(image: image, area: $match.referenceArea, showsArea: match.usesAreas)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(.secondary)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Drop an image here")
                                .font(.title3)
                            Text("A photo whose look you like: downloaded, a film still, or one of your own.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 300)
                        }
                    }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .frame(height: 300)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { match.useFile(url) } }
            }
            return true
        }
    }

    private var referenceButtons: some View {
        HStack {
            Button("Choose File…") { match.chooseFile() }
            Button("Catalog Photo…") { choosingCatalogPhoto = true }
                .help("Use a photo from the catalog with its current edits")
                .popover(isPresented: $choosingCatalogPhoto, arrowEdge: .bottom) {
                    CatalogPhotoPicker { id in
                        choosingCatalogPhoto = false
                        match.useCatalogPhoto(id)
                    }
                    .environmentObject(model)
                }
            Button("Built-in References") { choosingBuiltIn = true }
                .popover(isPresented: $choosingBuiltIn, arrowEdge: .bottom) {
                    BuiltInReferencePicker(selection: match.builtInReference) { reference in
                        choosingBuiltIn = false
                        match.useBuiltIn(reference)
                    }
                }
        }
        .fixedSize()
    }

    @ViewBuilder private var recentRow: some View {
        if !match.recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent References").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(match.recent) { reference in
                            RecentThumbnail(reference: reference)
                                .onTapGesture { match.useRecent(reference) }
                                .contextMenu {
                                    Button("Remove from Recent References") { match.removeRecent(reference) }
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: Photo

    private var photoImage: some View {
        ZStack {
            AreaImage(image: showingBefore ? match.before : match.preview, area: $match.photoArea,
                      showsArea: match.usesAreas && !showingBefore)
            if match.isLoadingReference || match.isMatching {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            }
        }
        .frame(height: 300)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Text("Match:")
                Toggle("White Balance", isOn: $match.options.whiteBalance)
                    .help("Temp and Tint")
                Toggle("Tone", isOn: $match.options.tone)
                    .help("Exposure and the Tone Curve")
                Toggle("Color", isOn: $match.options.color)
                    .help("Saturation, HSL and Color Grading (shadows and highlights)")
                Divider().frame(height: 16)
                Picker("Skin Tones:", selection: $match.skinMode) {
                    Text("Off").tag(LookSkinMode.off)
                    Text("Protect Skin Tones").tag(LookSkinMode.protect)
                    Text("Match Skin Tone").tag(LookSkinMode.match)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("match-look-skin-tones")
                .help("Keep face skin close to its current color or match its hue and saturation to the reference")
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 10) {
                Picker("Match Areas:", selection: $match.areaMode) {
                    ForEach(MatchAreaMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(match.builtInReference != nil)
                .help(match.builtInReference == nil ? match.areaMode.help : areaHint)
                Text(areaHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack {
                Text("Strength")
                Slider(value: $match.strength, in: 0...100)
                    .frame(maxWidth: 360)
                Text("\(Int(match.strength.rounded()))")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
                Button("Show Differences") { showingDifferences = true }
                    .disabled(!match.canApply)
                    .help("Which sliders Apply will move, and by how much")
                    .popover(isPresented: $showingDifferences, arrowEdge: .top) {
                        MatchDifferencesView(lines: match.differences)
                    }
                Spacer()
                if match.otherCount > 0 {
                    Picker("Apply to \(match.targets.count) photos:", selection: $match.applyMode) {
                        ForEach(MatchApplyMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(match.skinMode == .match)
                    .help(match.skinMode == .match
                          ? "Match Skin Tone fits the face mask separately on each photo."
                          : "Same settings: one match for all, like Sync. Match each photo: a match per photo, for mixed light.")
                }
            }
        }
    }

    private var areaHint: String {
        if match.builtInReference != nil { return "Built-in References use Whole Photo." }
        switch match.areaMode {
        case .wholePhoto: return "The whole reference sets the look for the whole photo."
        case .subject: return "Background matches background; a Match Look: Subject mask matches the subject."
        case .boxes: return "Drag each box over the parts that should match. Drag a corner to resize."
        }
    }

    private var footer: some View {
        HStack {
            if match.isLoadingReference {
                Text("Opening reference…").foregroundStyle(.secondary)
            } else if let message = match.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if match.isMatching {
                Text("Matching…").foregroundStyle(.secondary)
            } else if match.referenceImage == nil {
                Text("Choose a reference image to start.").foregroundStyle(.secondary)
            } else if let result = match.match {
                Text(result.skinMask != nil
                     ? "Edit face color after Apply in Masking → Match Look: Skin."
                     : result.subjectMask != nil
                         ? "Apply sets editable sliders and a Match Look: Subject mask."
                         : "Apply sets sliders you can keep editing in Develop.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                match.apply()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!match.canApply)
        }
    }
}

/// An image fitted into its space, with Match Areas' box drawn over it when shown.
struct AreaImage: View {
    let image: NSImage?
    @Binding var area: CGRect
    let showsArea: Bool

    var body: some View {
        GeometryReader { geometry in
            let frame = fitted(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.primary.opacity(0.06)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    if showsArea {
                        AreaBox(area: $area, frame: frame)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func fitted(in size: CGSize) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// Match Areas' box: drag inside to move it, drag the corner handle to resize it.
private struct AreaBox: View {
    @Binding var area: CGRect
    let frame: CGRect
    @State private var start: CGRect?

    private static let minimumSize = 0.08

    var body: some View {
        let rect = CGRect(x: frame.minX + area.minX * frame.width, y: frame.minY + area.minY * frame.height,
                          width: area.width * frame.width, height: area.height * frame.height)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.45), lineWidth: 4))
                .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    let from = start ?? area
                    start = from
                    var moved = from
                    moved.origin.x = min(1 - from.width, max(0, from.minX + value.translation.width / frame.width))
                    moved.origin.y = min(1 - from.height, max(0, from.minY + value.translation.height / frame.height))
                    area = moved
                }.onEnded { _ in start = nil })
                .cursor(.grab)
                .offset(x: rect.minX, y: rect.minY)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                .frame(width: 14, height: 14)
                .contentShape(Circle().inset(by: -6))
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    let from = start ?? area
                    start = from
                    var resized = from
                    resized.size.width = min(1 - from.minX, max(Self.minimumSize, from.width + value.translation.width / frame.width))
                    resized.size.height = min(1 - from.minY, max(Self.minimumSize, from.height + value.translation.height / frame.height))
                    area = resized
                }.onEnded { _ in start = nil })
                .cursor(.resize(.bottomRight))
                .offset(x: rect.maxX - 7, y: rect.maxY - 7)
        }
    }
}

private struct RecentThumbnail: View {
    let reference: RecentReference

    var body: some View {
        let exists = reference.exists
        ZStack {
            if let image = NSImage(data: reference.thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 42)
                    .clipped()
                    .opacity(exists ? 1 : 0.35)
            }
            if !exists {
                Text("Missing")
                    .font(.caption2.bold())
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.regularMaterial))
            }
        }
        .frame(width: 56, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .help(exists ? reference.name : "\(reference.name) was moved or deleted")
    }
}

/// Use a Photo from the Catalog…: the photos in the current view, as thumbnails.
private struct CatalogPhotoPicker: View {
    @EnvironmentObject private var model: LibraryModel
    let pick: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use a Photo from the Catalog").font(.headline)
            Text("The photo is used with its current edits.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(model.rows.prefix(400)) { row in
                        PickerThumbnail(row: row)
                            .onTapGesture { pick(row.id) }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 460, height: 380)
    }
}

private struct PickerThumbnail: View {
    @EnvironmentObject private var model: LibraryModel
    let row: AssetRow
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 96, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .help(row.filename)
        .task(id: row.id) {
            let id = row.id
            if let cached = ThumbnailLoader.shared.cached(id) {
                image = cached
            } else if let url = model.thumbnailURL(for: id) {
                ThumbnailLoader.shared.load(id, from: url) { loaded in image = loaded }
            }
        }
    }
}

/// Show Differences: each slider the match moves, from its current value to the matched one.
struct MatchDifferencesView: View {
    let lines: [MatchDifference]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apply will change").font(.headline)
            if lines.isEmpty {
                Text("Nothing: the photo already matches.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        ForEach(lines) { line in
                            GridRow {
                                Text(line.name)
                                Text(line.change).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
