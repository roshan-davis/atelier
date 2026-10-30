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
            }
            Spacer()
            if !cull.isReview {
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
                    Slider(value: $cull.looseness, in: 0...1)
                        .frame(width: 160)
                        .disabled(cull.isAnalyzing)
                    Text("Loose").font(.caption).foregroundStyle(.secondary)
                }
                .help("How alike shots must look to be grouped")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        if cull.isLoading { return "Finding photos…" }
        if cull.isAnalyzing { return "Looking at \(cull.analyzed) of \(cull.photos.count) photos…" }
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
                if let image = cull.largeImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else if cull.focused != nil {
                    ProgressView()
                }
            }
            if let id = cull.focused {
                previewBar(id)
            }
        }
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
                HStack(spacing: 10) {
                    if let sharpness = cull.relativeSharpness(of: id) {
                        Text("Sharpness \(Int((sharpness * 100).rounded()))% of the group's best")
                    }
                    if let face = photo.signals?.faceQuality {
                        Text("Face quality \(Int((face * 100).rounded()))%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .opacity(dimsWhenDropped && !isKept ? 0.4 : 1)
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
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isFocused ? Color.accentColor : (isKept && dimsWhenDropped ? Color.green.opacity(0.8) : Color.clear),
                              lineWidth: isFocused ? 3 : 2))
            Text(photo.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.width)
        }
        .contentShape(Rectangle())
        .help(isSuggested ? "Suggested keeper: sharpest, best faces" : photo.name)
    }
}

/// "RAW+JPG": the RAW stands for the files shot with it.
struct PairBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
            .help("Culled with the files shot alongside it; keeping or dropping applies to all of them")
    }
}
