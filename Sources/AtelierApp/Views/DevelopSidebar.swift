import AppKit
import AtelierCore
import SwiftUI

/// The left column in Develop, as in Lightroom: the Navigator pinned at the top, then presets,
/// snapshots and the edit history of the open photo, which scroll under it.
struct DevelopSidebar: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var develop: DevelopController
    @State private var naming: NameRequest?
    @State private var nameText = ""

    private enum NameRequest: Identifiable {
        case newSnapshot
        case renameSnapshot(UUID)

        var id: String {
            switch self {
            case .newSnapshot: return "new"
            case .renameSnapshot(let id): return id.uuidString
            }
        }
    }

    /// Sections minimized by clicking their header, remembered between launches.
    @AppStorage("develop.sidebarCollapsed") private var collapsedList = ""

    private static let sections = ["navigator", "presets", "snapshots", "history"]

    private func isExpanded(_ section: String) -> Binding<Bool> {
        Binding(get: { !collapsedList.split(separator: ",").contains(Substring(section)) }, set: { open in
            var collapsed = Set(collapsedList.split(separator: ",").map(String.init))
            if open { collapsed.remove(section) } else { collapsed.insert(section) }
            collapsedList = collapsed.sorted().joined(separator: ",")
        })
    }

    var body: some View {
        // The Navigator is pinned above the scrolling sections, as in Lightroom Classic, so a
        // preset's hover preview stays in view however far down the list is scrolled.
        VStack(spacing: 0) {
            SidebarSection(title: "Navigator", isExpanded: isExpanded("navigator")) {
                EmptyView()
            } content: {
                NavigatorView(develop: develop, zoom: model.zoomState)
            }
            Divider()
            // A plain stack rather than a List: List rebuilds its rows, which made the presets'
            // sheets flash as they closed.
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        PresetsSection(develop: develop, isExpanded: isExpanded("presets"))

                        SidebarSection(title: "Snapshots", isExpanded: isExpanded("snapshots")) {
                            Button {
                                nameText = Date().formatted(date: .abbreviated, time: .shortened)
                                naming = .newSnapshot
                            } label: {
                                Image(systemName: "plus")
                            }
                            .help("Create a snapshot of the current settings")
                            .disabled(develop.assetID == nil)
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                if develop.history.snapshots.isEmpty {
                                    Text("Save the current look to come back to it later.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(develop.history.snapshots) { snapshot in
                                    SidebarRow {
                                        Label(snapshot.name, systemImage: "camera.viewfinder")
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .onTapGesture { develop.applySnapshot(snapshot) }
                                    .help("Created \(snapshot.date.formatted(date: .abbreviated, time: .shortened)). Click to apply.")
                                    .contextMenu {
                                        Button("Apply") { develop.applySnapshot(snapshot) }
                                        Button("Update with Current Settings") { develop.updateSnapshot(snapshot.id) }
                                        Button("Rename…") {
                                            nameText = snapshot.name
                                            naming = .renameSnapshot(snapshot.id)
                                        }
                                        Divider()
                                        Button("Delete", role: .destructive) { develop.deleteSnapshot(snapshot.id) }
                                    }
                                }
                            }
                        }

                        SidebarSection(title: "History", isExpanded: isExpanded("history")) {
                            Button {
                                develop.clearHistory()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .help("Clear the history, keeping the current settings")
                            .disabled(develop.history.steps.count < 2)
                        } content: {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                if develop.history.steps.isEmpty {
                                    Text("Edits you make appear here. Click one to go back to it.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(Array(develop.history.steps.enumerated()).reversed(), id: \.offset) { index, step in
                                    SidebarRow(isCurrent: index == develop.history.position) {
                                        HistoryRow(step: step, isCurrent: index == develop.history.position,
                                                   isUndone: index > develop.history.position)
                                    }
                                    .onTapGesture { develop.go(to: index) }
                                }
                            }
                        }
                    }
                    // Tab order follows where controls sit in the column, whatever the scroll.
                    .coordinateSpace(.named(keyboardFocusSpace))
                }
                .environment(\.keyboardScroll, scroll)
            }
        }
        // ⌃Tab counts this column as the left area.
        .environment(\.keyboardFocusArea, .leftPanel)
        .contextMenu {
            Button("Expand All Sections") { collapsedList = "" }
            Button("Collapse All Sections") { collapsedList = Self.sections.joined(separator: ",") }
        }
        .alert(alertTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(alertAction) { commitName() }
                .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var alertTitle: String {
        if case .renameSnapshot = naming { return "Rename Snapshot" }
        return "New Snapshot"
    }

    private var alertAction: String {
        if case .renameSnapshot = naming { return "Rename" }
        return "Create"
    }

    private func commitName() {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch naming {
        case .newSnapshot: develop.createSnapshot(named: name)
        case .renameSnapshot(let id): develop.renameSnapshot(id, to: name)
        case nil: break
        }
        naming = nil
    }
}

private struct HistoryRow: View {
    let step: DevelopHistory.Step
    let isCurrent: Bool
    let isUndone: Bool

    var body: some View {
        HStack {
            Text(step.name)
                .lineLimit(1)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isUndone ? .tertiary : .primary)
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .help(step.date.formatted(date: .abbreviated, time: .standard))
    }
}

/// The VS Code–style header band every section in both Develop columns uses (Rosh's choice,
/// Oct 29, 2026): click anywhere on the band to minimize or show the section; a dot after the
/// title when it has edits; its buttons sit on the right, given the hover state to dim them.
/// A section of the Develop sidebar: a header band, then its content.
struct SidebarSection<Actions: View, Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SectionBand(title: title, isExpanded: $isExpanded) { hovering in
                if isExpanded {
                    HStack(spacing: 0) { actions() }
                        .buttonStyle(SidebarIconButtonStyle())
                        .opacity(hovering ? 1 : 0.6)
                }
            }

            if isExpanded {
                content()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Divider()
        }
        .clipped()
    }
}

/// A clickable sidebar row: highlighted under the pointer, and tinted when current.
struct SidebarRow<Content: View>: View {
    var isCurrent = false
    var onHover: ((Bool) -> Void)?
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isCurrent ? Color.accentColor.opacity(0.2) : Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                onHover?(inside)
            }
    }
}

/// Lightroom Classic's Navigator: the open photo, small. Resting the pointer on a preset shows
/// that preset here, so the big photo only changes when the preset is clicked. While the photo
/// is zoomed, a rectangle shows the part in view; click or drag here to move around the photo.
private struct NavigatorView: View {
    @ObservedObject var develop: DevelopController
    let zoom: ZoomState

    var body: some View {
        let previewing = develop.previewingPreset
        let image = (previewing != nil ? develop.navigatorPreview : nil) ?? develop.image
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.15)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                NavigatorViewport(viewport: zoom.viewport, zoom: zoom, imageSize: image.size)
            }
            if let previewing {
                Text(develop.navigatorPreview == nil ? "Previewing \(previewing.name)…" : previewing.name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Click or drag to move around the photo; rest the pointer on a preset to preview it here")
    }
}

/// The Navigator's rectangle over the part of the photo in view, and the click and drag that
/// move it. Watches only the viewport, so scrolling the photo redraws just this.
private struct NavigatorViewport: View {
    @ObservedObject var viewport: ZoomViewport
    let zoom: ZoomState
    let imageSize: CGSize
    /// From the pointer to the middle of the rectangle, kept while dragging so a rectangle
    /// grabbed off-center doesn't jump under the pointer.
    @State private var grab: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let photo = Self.fitted(imageSize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let visible = viewport.visible {
                    let rect = CGRect(x: photo.minX + visible.minX * photo.width, y: photo.minY + visible.minY * photo.height,
                                      width: visible.width * photo.width, height: visible.height * photo.height)
                    ZStack {
                        Rectangle().strokeBorder(Color.black.opacity(0.55), lineWidth: 3)
                        Rectangle().strokeBorder(Color.white, lineWidth: 1.5).padding(0.75)
                    }
                    .frame(width: max(4, rect.width), height: max(4, rect.height))
                    .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Path(photo))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let point = Self.relative(drag.location, in: photo)
                    if grab == nil {
                        if let visible = viewport.visible, visible.contains(point) {
                            grab = CGPoint(x: visible.midX - point.x, y: visible.midY - point.y)
                        } else {
                            grab = .zero
                        }
                    }
                    let offset = grab ?? .zero
                    zoom.focus?(CGPoint(x: min(1, max(0, point.x + offset.x)), y: min(1, max(0, point.y + offset.y))))
                }
                .onEnded { _ in
                    grab = nil
                })
            // A hand on the rectangle; elsewhere a click centers there. Either way a drag moves it.
            .cursor(whileDragging: .grabbing) { location in
                guard photo.contains(location) else { return .arrow }
                return viewport.visible?.contains(Self.relative(location, in: photo)) == true ? .grab : .link
            }
        }
    }

    /// Where an image of `size` sits when fitted into `bounds`, centered.
    private static func fitted(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// `location` as 0...1 across and down `photo`.
    private static func relative(_ location: CGPoint, in photo: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (location.x - photo.minX) / max(1, photo.width))),
                y: min(1, max(0, (location.y - photo.minY) / max(1, photo.height))))
    }
}
