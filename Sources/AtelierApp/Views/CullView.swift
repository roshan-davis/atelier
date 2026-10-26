import AppKit
import AtelierCore
import SwiftUI

/// Culling: similar shots in rows on the left, the focused photo large on the right. Kept
/// photos carry a check; the rest are dimmed.
struct CullView: View {
    @ObservedObject var cull: CullModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                groupList
                    .frame(minWidth: 420, idealWidth: 560)
                preview
                    .frame(minWidth: 360, idealWidth: 520)
            }
            Divider()
            footer
        }
        .frame(minWidth: 980, idealWidth: 1240, minHeight: 640, idealHeight: 800)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .space, "p", "x", "P", "X"]) { press in
            handle(press.key)
        }
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
        if cull.isAnalyzing { return "Looking at \(cull.analyzed) of \(cull.photos.count) photos…" }
        if cull.isReview {
            return "\(cull.photos.count) shots culled together · \(cull.keptCount) kept"
        }
        let groups = cull.multiGroups.count
        return "\(cull.photos.count) photos · \(groups) group\(groups == 1 ? "" : "s") of similar shots · \(cull.singles.count) single · \(cull.keptCount) kept"
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
                        ProgressView(value: Double(cull.analyzed), total: Double(max(cull.photos.count, 1)))
                            .padding(.horizontal, 4)
                        tiles(cull.photos.map(\.id), title: "Photos")
                    } else {
                        ForEach(Array(cull.multiGroups.enumerated()), id: \.offset) { index, group in
                            groupCard(group, title: cull.isReview ? "Culled together" : "Group \(index + 1)")
                        }
                        if !cull.singles.isEmpty {
                            groupCard(cull.singles, title: "Single shots", isSingles: true)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: theme.gridBackground))
            .onChange(of: cull.focused) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
    }

    private func groupCard(_ group: [Int], title: String, isSingles: Bool = false) -> some View {
        let kept = group.filter { cull.kept.contains($0) }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isSingles ? "photo" : "square.stack.3d.down.right")
                    .foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text("\(group.count) photo\(group.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if let time = cull.photos[group[0]].captureTime {
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
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    CullTile(photo: cull.photos[id], isKept: cull.kept.contains(id),
                             isSuggested: cull.suggested.contains(id), isFocused: cull.focused == id,
                             dimsWhenDropped: !cull.isAnalyzing)
                        .id(id)
                        .onTapGesture(count: 2) { cull.toggle(id) }
                        .onTapGesture { cull.focus(id) }
                        .contextMenu {
                            Button(cull.kept.contains(id) ? "Drop" : "Keep") { cull.toggle(id) }
                        }
                }
            }
            .padding(.bottom, 4)
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

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        guard !cull.isAnalyzing else { return .ignored }
        switch key {
        case .leftArrow: cull.move(-1, byGroup: false)
        case .rightArrow: cull.move(1, byGroup: false)
        case .upArrow: cull.move(-1, byGroup: true)
        case .downArrow: cull.move(1, byGroup: true)
        case .space: if let id = cull.focused { cull.toggle(id) }
        case "p", "P": if let id = cull.focused { cull.setKept(id, true); cull.move(1, byGroup: false) }
        case "x", "X": if let id = cull.focused { cull.setKept(id, false); cull.move(1, byGroup: false) }
        default: return .ignored
        }
        return .handled
    }
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
