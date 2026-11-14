import AppKit
import AtelierCore
import SwiftUI

/// Culling: similar shots in rows on the left, the focused photo large on the right. Kept
/// photos carry a check; the rest are dimmed.
struct CullView: View {
    @ObservedObject var cull: CullModel
    /// A step of the Import dialog, which shows its own title.
    var embedded = false
    @Environment(\.theme) private var theme
    @State private var keys = CullKeyMonitor()
    @AppStorage("cull.listWidth") private var listWidth = 560.0
    /// Notes pinned to a spot show as numbered markers on the preview (Rosh, Nov 14, 2026).
    @AppStorage("cull.noteMarkers") private var showMarkers = true
    /// Draw what was measured on the preview: the subject and each face's eyes.
    @AppStorage("cull.showSubject") private var showSubject = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if cull.isLoading {
                loadingStatus
            } else {
                // The list gets exactly the width it is given, so its rows wrap to the pane
                // (a split view would lay it out wider and clip both sides).
                GeometryReader { proxy in
                    let range = 420.0...max(420.0, Double(proxy.size.width) - 360)
                    let width = min(range.upperBound, max(range.lowerBound, listWidth))
                    HStack(spacing: 0) {
                        CullList(cull: cull, size: CGSize(width: width, height: proxy.size.height))
                            .clipped()
                        PanelResizeHandle(width: $listWidth, range: range, panel: .leading)
                        preview
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                }
            }
            footer
        }
        .frame(minWidth: 980, idealWidth: 1240, minHeight: 600, idealHeight: 800)
        // The keys work as soon as the view is up, whatever has keyboard focus in the window
        // (except a text field), so nothing has to be clicked first.
        .background(WindowAccessor { keys.window = $0 })
        .onAppear { keys.start(handle) }
        .onDisappear { keys.stop() }
    }

    // MARK: Status while it works

    /// Before the photos are listed: what is happening, with a count and a bar.
    private var loadingStatus: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            if let found = cull.found {
                Text("Reading \(found) photo\(found == 1 ? "" : "s")…").font(.title3.weight(.semibold))
                ProgressView(value: Double(cull.read), total: Double(max(found, 1)))
                    .frame(width: 360)
                Text("Capture times, to put the shots in order: \(cull.read) of \(found)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Finding photos…").font(.title3.weight(.semibold))
                ProgressView().progressViewStyle(.linear).frame(width: 360)
                Text("Looking through the folders you chose")
                    .foregroundStyle(.secondary)
            }
            Text("Next, each photo is checked for sharpness, faces and similar shots. You can look through them with the arrow keys while that runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.gridBackground))
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                if !embedded {
                    Text(cull.title).font(.title2.bold())
                }
                Text(subtitle)
                    .font(embedded ? .headline : .body)
                    .foregroundStyle(embedded ? .primary : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                if !cull.isReview {
                    HStack(spacing: 16) {
                        Picker("Match", selection: $cull.mode) {
                            Text("Same Frame").tag(CullMode.sameFrame)
                            Text("Similar Shots").tag(CullMode.similarShots)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(cull.isAnalyzing)
                        .help(cull.mode == .sameFrame
                              ? "Same Frame: only shots framed alike, where people moved a little or blinked"
                              : "Similar Shots: also slight zooms and recomposing, people moving in the background, a change of focus")
                        HStack(spacing: 8) {
                            Text("Grouping").foregroundStyle(.secondary)
                            Text("Tight").font(.caption).foregroundStyle(.secondary)
                            DevelopSlider(value: $cull.looseness, range: 0...1, step: 0, origin: 0, gradient: nil,
                                          name: "Grouping")
                                .frame(width: 160)
                                .disabled(cull.isAnalyzing)
                            Text("Loose").font(.caption).foregroundStyle(.secondary)
                        }
                        .help("How alike shots must look to be grouped")
                    }
                }
                // How faces are found and which photo of each group is suggested; grouping
                // doesn't change with these. One row when it fits, else two, never wrapped.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        findFacesPicker
                        pickByPicker
                        advancedToggle
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 20) {
                            findFacesPicker
                            pickByPicker
                        }
                        advancedToggle
                    }
                }
            }
            // The controls keep their width; the title and subtitle give way (truncate).
            .layoutPriority(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var pickByPicker: some View {
        Picker("Pick By", selection: $cull.pickBy) {
            ForEach(CullPick.allCases) { pick in
                Text(pick.title).tag(pick)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(cull.isAnalyzing)
        .help("How the suggested keeper of each group is chosen. \(cull.pickBy.title): \(cull.pickBy.help)")
    }

    private var findFacesPicker: some View {
        Picker("Find Faces", selection: $cull.faceFinder) {
            ForEach(CullFaceFinder.allCases) { finder in
                Text(finder.title).tag(finder)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Which face detector finds the faces Cull checks. \(cull.faceFinder.title): \(cull.faceFinder.help). "
              + "Every photo is read with each, so switching only picks again.")
    }

    private var advancedToggle: some View {
        Toggle("Advanced checks (slower)", isOn: $cull.advanced)
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("Reads the eyes of every grouped photo again from a large copy: small faces in group "
                  + "shots get checked, Sharpness compares the eyes themselves, and a built-in face model "
                  + "reads blinks and smiles (needed for Best Expression). Roughly a fifth of a second "
                  + "more per grouped photo; single shots are skipped.")
    }

    private var subtitle: String {
        if cull.isLoading { return "Finding photos…" }
        if cull.isAnalyzing { return "Looking at \(cull.analyzed) of \(cull.photos.count) photos…" }
        if let progress = cull.advancedProgress {
            return "Advanced checks: reading eyes and smiles in \(progress.done) of \(progress.total) grouped photos…"
        }
        if cull.isReview {
            return "\(cull.photos.count) shots culled together · \(cull.keptCount) kept"
        }
        let groups = cull.multiGroups.count
        let kind = cull.mode == .sameFrame ? "same-frame shots" : "similar shots"
        return "\(cull.photos.count) photos · \(groups) group\(groups == 1 ? "" : "s") of \(kind) · \(cull.singles.count) single · \(cull.keptCount) kept"
    }

    private var footer: some View {
        ImportFooter {
            if let ahead = cull.ahead, ahead.total > 0 {
                aheadStatus(ahead)
            } else {
                Text("Click to look · Space or double-click keeps or drops · P keep · X drop · arrows move")
            }
        } buttons: {
            if !cull.isReview || cull.photos.count > 1 {
                Toggle("Write reasons to notes", isOn: $cull.writeReasons)
                    .toggleStyle(.checkbox)
                    .help("When you finish, each photo not kept gets a note saying why (eyes closed, softer than the keeper…)")
            }
            Button("Keep All") { cull.keepAll() }
                .disabled(cull.isAnalyzing)
            if let back = cull.onBack {
                Button("Back") {
                    cull.stop()
                    back()
                }
            }
            Button("Cancel", role: .cancel) { cull.cancel() }
                .keyboardShortcut(.cancelAction)
            Button(finishTitle) { cull.finish() }
                .keyboardShortcut(.defaultAction)
                .disabled(cull.isAnalyzing || cull.keptCount == 0)
        }
    }

    /// While the user culls, the files are copied to the library, so Import is quick.
    private func aheadStatus(_ ahead: ImportStager.Progress) -> some View {
        HStack(spacing: 6) {
            if ahead.isFinished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(ahead.copying ? "All \(ahead.total) files copied to your library ahead; Import only files them"
                     : "All \(ahead.total) files checked ahead; Import will be quick")
            } else {
                ProgressView(value: Double(ahead.done), total: Double(max(ahead.total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("\(ahead.copying ? "Copying to your library" : "Checking files") while you cull: \(ahead.done) of \(ahead.total)")
                    .monospacedDigit()
            }
        }
        .help("Atelier copies the photos while you cull, so Import has less to do. Back or Cancel discards these copies.")
    }

    private var finishTitle: String {
        if cull.isAnalyzing || cull.isLoading { return cull.isImporting ? "Import" : "Done" }
        if cull.isImporting { return "Import \(cull.keptCount) Photo\(cull.keptCount == 1 ? "" : "s")" }
        return cull.isReview ? "Done" : "Pick \(cull.keptCount), Reject \(cull.droppedCount)"
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: theme.surround)
                if let image = cull.fullImage ?? cull.largeImage {
                    // The same zooming photo view as Loupe and Develop: double-click, Z, pinch,
                    // ⌥-scroll and the zoom bar zoom; drag moves around.
                    ZoomableImageView(image: image, pixelSize: cull.pixelSize, zoom: cull.zoom,
                                      onReport: { report in
                                          if cull.zoom.report != report {
                                              cull.zoom.report = report
                                              cull.zoomChanged()
                                          }
                                      },
                                      menu: { nil },
                                      onPick: cull.placingNote == nil ? nil : { (point: CGPoint) in cull.placeNote(at: point) },
                                      overlay: markersOverlay,
                                      overlayPassesClicks: true)
                } else if cull.focused != nil {
                    ProgressView()
                }
            }
            // The same sticky notes as Library (AT-058), for the focused shot.
            .overlay {
                if let catalog = cull.catalog, let id = cull.focused {
                    NotesOverlay(catalog: catalog, assetID: cull.focusedAssetID, subtitle: cull.photos[id].name,
                                 addTargets: { cull.focusedAssetID.map { [$0] } ?? [] },
                                 unavailable: cull.focusedAssetID == nil
                                    ? "Notes can be added once the photos are imported." : nil,
                                 request: $cull.noteRequest,
                                 pins: NotePins(placing: cull.placingNote,
                                                place: { note in
                                                    showMarkers = true
                                                    cull.placingNote = note.id
                                                },
                                                remove: { cull.removePin($0) }))
                }
            }
            .onChange(of: cull.focusedAssetID, initial: true) { _, id in cull.markerNotes?.show(id) }
            if let id = cull.focused {
                Divider()
                zoomBar
                previewBar(id)
            }
        }
    }

    /// What is drawn over the photo: the measured subject and faces (Show Subject) and the note
    /// markers (Note Markers), or nil with both off.
    private var markersOverlay: ((PhotoFrame) -> AnyView)? {
        let notes = showMarkers ? cull.markerNotes : nil
        let measured = showSubject ? cull.focused.flatMap { id in cull.photos[id].signals.map { (id, $0) } } : nil
        guard notes != nil || measured != nil else { return nil }
        let faces = measured.map { cull.previewFaces(of: $0.0) } ?? []
        let assessment = measured.flatMap { cull.assessments[$0.0] }
        return { frame in
            AnyView(ZStack {
                if let measured {
                    CullSubjectOverlay(frame: frame, subject: assessment?.subject ?? measured.1.subject, faces: faces)
                }
                if let notes {
                    NoteMarkersOverlay(notes: notes, frame: frame)
                }
            })
        }
    }

    /// The hint, the two display switches side by side and the zoom buttons, laid out like
    /// Loupe's bar: the hint goes first when room runs out, the switches never wrap.
    private var zoomBar: some View {
        AdaptiveControlBar(sizingKey: cull.placingNote != nil) {
            HStack(spacing: 12) {
                zoomHint
                Spacer(minLength: 16)
                displaySwitches
                ZoomControls(zoom: cull.zoom)
            }
        } compact: {
            HStack(spacing: 12) {
                displaySwitches
                Spacer(minLength: 8)
                ZoomControls(zoom: cull.zoom)
            }
        } minimum: {
            HStack(spacing: 8) {
                displaySwitches
                Spacer(minLength: 0)
                ZoomControls(zoom: cull.zoom, compact: true)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var zoomHint: some View {
        Text(cull.placingNote != nil ? "Click the photo where the note belongs (Esc stops)"
                                     : "Double-click the photo to zoom, drag to move around")
            .foregroundStyle(cull.placingNote != nil ? Color.accentColor : .secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// What to draw on the photo: one group, read left to right.
    private var displaySwitches: some View {
        HStack(spacing: 14) {
            Toggle("Show Subject", isOn: $showSubject)
                .help("Draw what Cull measured: a dashed box around the area its sharpness is read on "
                      + "(the faces, the people, Vision's main object or the whole frame) and each face with its eyes")
            Toggle("Note Markers", isOn: $showMarkers)
                .help("Show notes pinned to a spot on the photo as numbered markers. Pin a note with "
                      + "Pin to Photo in the notes panel. Markers show only here, never in exports.")
        }
        .toggleStyle(.checkbox)
        .fixedSize()
    }

    private func subjectLine(_ id: Int) -> String? {
        guard let signals = cull.photos[id].signals else { return nil }
        let assessment = cull.assessments[id]
        return CullSubjectOverlay.describe(subject: assessment?.subject ?? signals.subject,
                                           sharedRegion: assessment?.sharedRegion ?? false,
                                           faceCount: signals.faces.count)
    }

    private func previewBar(_ id: Int) -> some View {
        let photo = cull.photos[id]
        let kept = cull.kept.contains(id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(photo.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let badge = photo.pairBadge {
                        PairBadge(text: badge)
                    }
                    if cull.suggested.contains(id) {
                        Label("Suggested", systemImage: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.yellow)
                    }
                }
                if let caption = cull.caption(of: id) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(caption)
                }
                // What Show Subject draws, in words (no text on the photo).
                if showSubject, let line = subjectLine(id) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(CullSubjectOverlay.subjectColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(line + "\n" + CullSubjectOverlay.legend)
                }
                // Why it isn't kept, as its note will say when the cull ends.
                if let reasons = cull.reasons(of: id), !reasons.isEmpty {
                    Text("Not kept: " + reasons.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(reasons.joined(separator: "\n"))
                }
            }
            Spacer()
            Picker("", selection: Binding(get: { kept }, set: { cull.setKept(id, $0) })) {
                Label("Keep", systemImage: "checkmark.circle.fill").tag(true)
                Label("Drop", systemImage: "xmark.circle").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // Keepers are suggested once every photo is checked.
            .disabled(cull.isAnalyzing)
            .opacity(cull.isAnalyzing ? 0 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Keys

    /// Left and right move through the photos, up and down a group at a time; P keeps, X drops,
    /// Space toggles. While the photos are analyzed the arrows already move through them.
    private func handle(_ event: NSEvent) -> Bool {
        if cull.isLoading { return false }
        // Esc while a note waits to be pinned stops that, not the cull.
        if event.keyCode == 53, cull.placingNote != nil {
            cull.placingNote = nil
            return true
        }
        if KeyBindings.action(for: event) == .zoom, cull.focused != nil {
            cull.toggleZoom()
            return true
        }
        switch event.keyCode {
        case 123: cull.move(-1, byRow: false)
        case 124: cull.move(1, byRow: false)
        case 126: cull.move(-1, byRow: true)
        case 125: cull.move(1, byRow: true)
        default:
            guard !cull.isAnalyzing, let id = cull.focused else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": cull.toggle(id)
            case "p": cull.setKept(id, true); cull.move(1, byRow: false)
            case "x": cull.setKept(id, false); cull.move(1, byRow: false)
            default: return false
            }
        }
        return true
    }
}

/// The Cull view's keys, from a key-down monitor on its own window, so they work without
/// clicking into the view first.
final class CullKeyMonitor {
    weak var window: NSWindow?
    private var monitor: Any?

    func start(_ handle: @escaping (NSEvent) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let window = self?.window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let handled = MainActor.assumeIsolated { handle(event) }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

/// One thumbnail: a check when kept, dimmed when dropped, a star on the suggested keeper.
struct CullTile: View {
    /// Every tile is this wide, so rows can be laid out and scrolled without measuring.
    static let width = 150.0
    static let spacing = 8.0
    static var stride: Double { width + spacing }

    let photo: CullPhoto
    let isKept: Bool
    let isSuggested: Bool
    let isFocused: Bool
    let dimsWhenDropped: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = photo.thumbnail {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: Self.width, height: 104)
                .opacity(dimsWhenDropped && !isKept ? ThumbnailState.rejectedOpacity : 1)
                if dimsWhenDropped {
                    Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isKept ? Color.white : Color.white.opacity(0.7), isKept ? Color.green : Color.clear)
                        .shadow(radius: 2)
                        .padding(5)
                }
                if let badge = photo.pairBadge {
                    PairBadge(text: badge)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if isSuggested {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                        .shadow(radius: 2)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: Self.width, height: 104)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: ThumbnailState.cornerRadius))
            // The same focus ring as the grid and Filmstrip; kept photos get a green one.
            .thumbnailFrame(isFocused ? .focused : .unselected)
            .overlay {
                if isKept && dimsWhenDropped && !isFocused {
                    RoundedRectangle(cornerRadius: ThumbnailState.cornerRadius)
                        .strokeBorder(Color.green.opacity(0.8), lineWidth: 2)
                }
            }
            Text(photo.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.width)
        }
        .contentShape(Rectangle())
        .help(isSuggested ? "Suggested keeper (see Pick By)" : photo.name)
    }
}

/// "RAW+JPG": the RAW stands for the files shot with it.
struct PairBadge: View {
    let text: String

    var body: some View {
        OverlayPill { Text(text) }
            .help("Culled with the files shot alongside it; keeping or dropping applies to all of them")
    }
}
