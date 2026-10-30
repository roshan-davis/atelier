import AppKit
import AtelierCore
import SwiftUI

/// Culling: similar shots in rows on the left, the focused photo large on the right. Kept
/// photos carry a check; the rest are dimmed.
struct CullView: View {
    @ObservedObject var cull: CullModel
    @Environment(\.theme) private var theme
    @State private var keys = CullKeyMonitor()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if cull.isLoading {
                loadingStatus
            } else {
                HSplitView {
                    groupList
                        .frame(minWidth: 420, idealWidth: 560)
                    preview
                        .frame(minWidth: 360, idealWidth: 520)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 980, idealWidth: 1240, minHeight: 640, idealHeight: 800)
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
            Text(analysisTimeLeft ?? "Groups and suggested keepers appear when every photo is checked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: theme.panel).opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
    }

    private var analysisTimeLeft: String? {
        guard let start = cull.analysisStarted, cull.analyzed >= 4 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let left = elapsed / Double(cull.analyzed) * Double(cull.photos.count - cull.analyzed)
        let time = DateComponentsFormatter()
        time.unitsStyle = .full
        time.maximumUnitCount = 1
        time.allowedUnits = left < 60 ? [.second] : [.hour, .minute]
        guard let text = time.string(from: max(left, 1).rounded(.up)) else { return nil }
        return "About \(text) left. Groups and suggested keepers appear when every photo is checked."
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(cull.title).font(.title2.bold())
                Text(subtitle)
                    .foregroundStyle(.secondary)
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
        HStack(spacing: 10) {
            Text("Click to look · Space or double-click keeps or drops · P keep · X drop · arrows move")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var finishTitle: String {
        if cull.isImporting { return "Import \(cull.keptCount) Photo\(cull.keptCount == 1 ? "" : "s")" }
        return cull.isReview ? "Done" : "Pick \(cull.keptCount), Reject \(cull.droppedCount)"
    }

    // MARK: Groups

    private var groupList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if cull.isAnalyzing {
                        analysisStatus
                        // Every photo in capture order, wrapped, until the groups are ready.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(cull.photos.map(\.id), id: \.self) { id in
                                tile(id).id(id)
                            }
                        }
                    } else {
                        ForEach(Array(cull.multiGroups.enumerated()), id: \.offset) { index, group in
                            groupCard(group, title: cull.isReview ? "Culled together" : "Group \(index + 1)",
                                      kind: cull.isReview ? nil : (cull.isSameFrame(group) ? "Same frame" : "Similar shots"))
                                .id(CardID.group(index))
                        }
                        if !cull.singles.isEmpty {
                            groupCard(cull.singles, title: "Single shots", isSingles: true)
                                .id(CardID.singles)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: theme.gridBackground))
            // Only the arrow keys scroll, by the least that shows the photo's group. Clicking a
            // photo never moves the list.
            .onChange(of: cull.reveal) { _, reveal in
                guard let reveal else { return }
                if cull.isAnalyzing {
                    proxy.scrollTo(reveal.id)
                    return
                }
                guard let card = cardID(of: reveal.id) else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(card) }
            }
            .onChange(of: cull.isAnalyzing) { _, analyzing in
                // The groups replace the analysis list: start at the top.
                if !analyzing { proxy.scrollTo(CardID.group(0), anchor: .top) }
            }
        }
    }

    private enum CardID: Hashable {
        case group(Int)
        case singles
    }

    private func cardID(of id: Int) -> CardID? {
        if let index = cull.multiGroups.firstIndex(where: { $0.contains(id) }) { return .group(index) }
        return cull.singles.contains(id) ? .singles : nil
    }

    private func groupCard(_ group: [Int], title: String, kind: String? = nil, isSingles: Bool = false) -> some View {
        let kept = group.filter { cull.kept.contains($0) }.count
        return VStack(alignment: .leading, spacing: 8) {
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
                Text("\(group.count) photo\(group.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if !isSingles, let time = cull.photos[group[0]].captureTime {
                    Text(time.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(kept == 0 ? "None kept" : "\(kept) kept")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(kept == 0 ? Color.orange.opacity(0.25) : Color.green.opacity(0.22), in: Capsule())
            }
            tiles(group, title: title)
        }
        .padding(12)
        .background(Color(nsColor: theme.panel).opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(group.contains(cull.focused ?? -1) ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18)))
    }

    private func tiles(_ ids: [Int], title: String) -> some View {
        ScrollViewReader { row in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        tile(id).id(id)
                    }
                }
                .padding(.bottom, 4)
            }
            // A long row follows the arrow keys sideways.
            .onChange(of: cull.reveal) { _, reveal in
                guard let reveal, ids.contains(reveal.id) else { return }
                row.scrollTo(reveal.id)
            }
        }
    }

    private func tile(_ id: Int) -> some View {
        CullTile(photo: cull.photos[id], isKept: cull.kept.contains(id),
                 isSuggested: cull.suggested.contains(id), isFocused: cull.focused == id,
                 dimsWhenDropped: !cull.isAnalyzing)
            .onTapGesture(count: 2) { cull.toggle(id) }
            .onTapGesture { cull.focus(id) }
            .contextMenu {
                Button(cull.kept.contains(id) ? "Drop" : "Keep") { cull.toggle(id) }
            }
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
        case 123: cull.move(-1, byGroup: false)
        case 124: cull.move(1, byGroup: false)
        case 126: cull.move(-1, byGroup: true)
        case 125: cull.move(1, byGroup: true)
        default:
            guard !cull.isAnalyzing, let id = cull.focused else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": cull.toggle(id)
            case "p": cull.setKept(id, true); cull.move(1, byGroup: false)
            case "x": cull.setKept(id, false); cull.move(1, byGroup: false)
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
private struct CullTile: View {
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
                .frame(width: 150, height: 104)
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
            .frame(width: 150, height: 104)
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
                .frame(width: 150)
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
