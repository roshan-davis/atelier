import AppKit
import AtelierCore
import SwiftUI

/// The notes panel's place and look (AT-058): one set of preferences every view reads, so it is
/// where it was in Library, Loupe, Cull and Develop, and after a relaunch.
enum NotesPanel {
    static let visibleKey = "notes.visible"
    static let cornerKey = "notes.corner"
    static let widthKey = "notes.width"
    static let heightKey = "notes.height"
    static let fontKey = "notes.font"

    static let defaultWidth = 280.0
    static let defaultHeight = 240.0
    static let widthRange = 220.0...520.0
    static let heightRange = 150.0...640.0
    /// From the edges of the photo area.
    static let inset = 12.0

    /// View > Show Notes (⌥⌘N, the `view.showNotes` action). Hidden until first shown.
    static var isVisible: Bool {
        get { UserDefaults.standard.bool(forKey: visibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: visibleKey) }
    }
}

/// The corner of the photo area the panel sits in; dragging its top strip moves it to another.
enum NotesCorner: String, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isTop: Bool { self == .topLeading || self == .topTrailing }

    init(leading: Bool, top: Bool) {
        switch (leading, top) {
        case (true, true): self = .topLeading
        case (false, true): self = .topTrailing
        case (true, false): self = .bottomLeading
        case (false, false): self = .bottomTrailing
        }
    }

    /// The resize grip is on the corner facing the middle of the photo.
    var gripPosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeading: return .bottomRight
        case .topTrailing: return .bottomLeft
        case .bottomLeading: return .topRight
        case .bottomTrailing: return .topLeft
        }
    }

    var gripAlignment: Alignment {
        switch self {
        case .topLeading: return .bottomTrailing
        case .topTrailing: return .bottomLeading
        case .bottomLeading: return .topTrailing
        case .bottomTrailing: return .topLeading
        }
    }
}

/// Settings > Appearance > Notes Font.
enum NotesFont: String, CaseIterable, Identifiable {
    /// Noteworthy, the handwriting-style font that ships with macOS (nothing bundled).
    case handwriting
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .handwriting: return "Handwriting (Noteworthy)"
        case .system: return "System"
        }
    }

    static let size: CGFloat = 15
    static let systemSize: CGFloat = 13

    func nsFont(bold: Bool = false) -> NSFont {
        switch self {
        case .handwriting:
            return NSFont(name: bold ? "Noteworthy-Bold" : "Noteworthy-Light", size: Self.size)
                ?? .systemFont(ofSize: Self.systemSize, weight: bold ? .semibold : .regular)
        case .system:
            return .systemFont(ofSize: Self.systemSize, weight: bold ? .semibold : .regular)
        }
    }

    var font: Font { Font(nsFont()) }
}

/// The sticky note's colors: pale yellow paper with dark ink, toned down in dark themes so it
/// doesn't glare beside the photo.
struct NotesPalette {
    let paper: NSColor
    let header: NSColor
    let ink: NSColor
    let faint: NSColor

    static func forDark(_ dark: Bool) -> NotesPalette {
        dark
            ? NotesPalette(paper: NSColor(srgbRed: 0.33, green: 0.30, blue: 0.17, alpha: 0.97),
                           header: NSColor(srgbRed: 0.40, green: 0.36, blue: 0.20, alpha: 1),
                           ink: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.80, alpha: 1),
                           faint: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.80, alpha: 0.55))
            : NotesPalette(paper: NSColor(srgbRed: 1.0, green: 0.96, blue: 0.70, alpha: 0.98),
                           header: NSColor(srgbRed: 0.98, green: 0.90, blue: 0.52, alpha: 1),
                           ink: NSColor(srgbRed: 0.20, green: 0.17, blue: 0.08, alpha: 1),
                           faint: NSColor(srgbRed: 0.20, green: 0.17, blue: 0.08, alpha: 0.55))
    }
}

/// What Photo > Add Note… asks the panel to do: a new note on the first photo, also added to the
/// others when typing ends.
struct NoteRequest: Equatable {
    let id = UUID()
    let assetIDs: [Int64]
}

/// The notes panel floating over a corner of the photo area. It is an overlay, so showing,
/// hiding, moving or resizing it never changes the photo view's size, zoom, pan or the grid's
/// scroll position.
struct NotesOverlay: View {
    /// The photo whose notes show; nil shows nothing.
    let assetID: Int64?
    /// "DSC_0101.NEF" or "DSC_0101.NEF · 12 selected".
    let subtitle: String
    /// Every photo a new note goes to (the selection), the shown one included. Asked only when
    /// a note is started, so a large selection costs nothing while the panel just shows.
    let addTargets: () -> [Int64]
    /// Why the photo can't take notes yet (a photo still being imported), shown instead of them.
    var unavailable: String? = nil
    @Binding var request: NoteRequest?
    @StateObject private var notes: PhotoNotesModel

    @AppStorage(NotesPanel.visibleKey) private var visible = false
    @AppStorage(NotesPanel.cornerKey) private var corner: NotesCorner = .topTrailing
    @AppStorage(NotesPanel.widthKey) private var width = NotesPanel.defaultWidth
    @AppStorage(NotesPanel.heightKey) private var height = NotesPanel.defaultHeight
    @State private var drag: CGSize = .zero
    @State private var resizeStart: CGSize?

    init(catalog: Catalog, assetID: Int64?, subtitle: String, addTargets: @escaping () -> [Int64], unavailable: String? = nil,
         request: Binding<NoteRequest?> = .constant(nil)) {
        self.assetID = assetID
        self.subtitle = subtitle
        self.addTargets = addTargets
        self.unavailable = unavailable
        _request = request
        _notes = StateObject(wrappedValue: PhotoNotesModel(catalog: catalog))
    }

    var body: some View {
        GeometryReader { proxy in
            if visible, assetID != nil || unavailable != nil {
                let size = panelSize(in: proxy.size)
                NotesPanelView(notes: notes, subtitle: subtitle, unavailable: unavailable,
                               corner: corner, addTargets: addTargets,
                               moved: { drag = $0 }, dropped: { drop($0, area: proxy.size, size: size) },
                               resized: { resize(by: $0, area: proxy.size) }, resizeEnded: { resizeStart = nil },
                               hide: { visible = false })
                    .frame(width: size.width, height: size.height)
                    .offset(drag)
                    .padding(NotesPanel.inset)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: corner.alignment)
            }
        }
        .onChange(of: assetID, initial: true) { _, id in notes.show(id) }
        .onChange(of: visible) { _, shown in if !shown { notes.finishEditing() } }
        .onChange(of: request, initial: true) { _, newRequest in
            guard let newRequest, let first = newRequest.assetIDs.first, first == assetID else { return }
            request = nil
            notes.show(first)  // in case this runs before the photo change above
            notes.startNewNote(alsoFor: newRequest.assetIDs)
        }
        .onDisappear { notes.finishEditing() }
    }

    /// The saved size, made to fit a small window.
    private func panelSize(in area: CGSize) -> CGSize {
        let room = CGSize(width: max(area.width - 2 * NotesPanel.inset, 120),
                          height: max(area.height - 2 * NotesPanel.inset, 100))
        return CGSize(width: min(width, room.width), height: min(height, room.height))
    }

    /// The top strip was let go: the panel goes to the corner nearest where it was dropped.
    private func drop(_ translation: CGSize, area: CGSize, size: CGSize) {
        let startX = corner.isLeading ? NotesPanel.inset + size.width / 2 : area.width - NotesPanel.inset - size.width / 2
        let startY = corner.isTop ? NotesPanel.inset + size.height / 2 : area.height - NotesPanel.inset - size.height / 2
        let center = CGPoint(x: startX + translation.width, y: startY + translation.height)
        withAnimation(.easeOut(duration: 0.18)) {
            corner = NotesCorner(leading: center.x < area.width / 2, top: center.y < area.height / 2)
            drag = .zero
        }
    }

    /// The grip faces the middle of the photo, so dragging it toward the middle makes the panel bigger.
    private func resize(by translation: CGSize, area: CGSize) {
        let start = resizeStart ?? CGSize(width: width, height: height)
        if resizeStart == nil { resizeStart = start }
        let dx = corner.isLeading ? translation.width : -translation.width
        let dy = corner.isTop ? translation.height : -translation.height
        let maxWidth = min(NotesPanel.widthRange.upperBound, area.width - 2 * NotesPanel.inset)
        let maxHeight = min(NotesPanel.heightRange.upperBound, area.height - 2 * NotesPanel.inset)
        width = min(max(start.width + dx, NotesPanel.widthRange.lowerBound), max(maxWidth, NotesPanel.widthRange.lowerBound))
        height = min(max(start.height + dy, NotesPanel.heightRange.lowerBound), max(maxHeight, NotesPanel.heightRange.lowerBound))
    }
}

/// The sticky note itself: a header strip to drag, the photo's notes, and Undo after a delete.
struct NotesPanelView: View {
    @ObservedObject var notes: PhotoNotesModel
    let subtitle: String
    let unavailable: String?
    let corner: NotesCorner
    let addTargets: () -> [Int64]
    let moved: (CGSize) -> Void
    let dropped: (CGSize) -> Void
    let resized: (CGSize) -> Void
    let resizeEnded: () -> Void
    let hide: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(NotesPanel.fontKey) private var fontChoice: NotesFont = .handwriting

    private var palette: NotesPalette { .forDark(colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color(nsColor: palette.faint).opacity(0.4))
            content
        }
        .background(Color(nsColor: palette.paper))
        .clipShape(StickyShape())
        .overlay(alignment: .bottomTrailing) { foldedCorner }
        .overlay(alignment: corner.gripAlignment) { grip }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .environment(\.colorScheme, colorScheme)
        // Over the photo, the panel's own cursor wins (a photo view's hand or crosshair never
        // shows through it).
        .cursor(.arrow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("Notes").font(.system(size: 11, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.7)
            }
            Spacer(minLength: 4)
            if notes.isEditing {
                Button("Done") { notes.finishEditing() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .help("Finish this note (Esc or ⌘Return)")
                    .cursor(.link)
            } else if unavailable == nil {
                Button { notes.startNewNote(alsoFor: addTargets()) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Add a note, to every selected photo (⌥⇧⌘N)")
                .cursor(.link)
            }
            Button(action: hide) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Hide Notes (⌥⌘N)")
            .cursor(.link)
        }
        .foregroundStyle(Color(nsColor: palette.ink))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: palette.header))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { moved($0.translation) }
            .onEnded { dropped($0.translation) })
        .cursor(.grab)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let unavailable {
            placeholder(unavailable)
        } else if notes.isEditing {
            VStack(alignment: .leading, spacing: 4) {
                if notes.alsoFor.count > 0 {
                    Text("Adding to \(notes.alsoFor.count + 1) photos")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: palette.faint))
                }
                NoteEditor(text: notes.draft, font: fontChoice, palette: palette,
                           changed: { notes.draftChanged($0) }, finished: { notes.finishEditing() })
                    .cursor(.text)
                if let editing = notes.editingID, let note = notes.notes.first(where: { $0.id == editing }) {
                    meta(note)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let written = notes.notes.filter { !NoteText.cleaned($0.text).isEmpty }
            if written.isEmpty && notes.recentlyDeleted == nil {
                placeholder("No notes yet. Click + to write one.")
                    .contentShape(Rectangle())
                    .onTapGesture { notes.startNewNote(alsoFor: addTargets()) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if notes.recentlyDeleted != nil { deletedRow }
                        ForEach(written, id: \.id) { note in
                            NoteCard(note: note, font: fontChoice, palette: palette,
                                     edit: { notes.beginEditing(note) },
                                     toggle: { notes.toggleCheckbox(note, line: $0) },
                                     delete: { notes.delete(note) })
                            meta(note)
                            if note.id != written.last?.id {
                                Divider().overlay(Color(nsColor: palette.faint).opacity(0.3))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(fontChoice.font)
            .foregroundStyle(Color(nsColor: palette.faint))
            .multilineTextAlignment(.center)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "You · Nov 14, 2026 at 4:26 PM · edited Nov 15" in the system font, small and gray.
    private func meta(_ note: PhotoNote) -> some View {
        var text = "\(note.author) · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))"
        if let edited = note.editedAt { text += " · edited \(edited.formatted(date: .abbreviated, time: .shortened))" }
        return Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Color(nsColor: palette.faint))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var deletedRow: some View {
        HStack {
            Text("Note deleted").font(.system(size: 11))
            Spacer()
            Button("Undo") { notes.undoDelete() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .cursor(.link)
        }
        .foregroundStyle(Color(nsColor: palette.ink))
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: palette.header).opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: Paper

    private var foldedCorner: some View {
        FoldShape()
            .fill(Color(nsColor: palette.header))
            .overlay(FoldShape().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
            .frame(width: StickyShape.fold, height: StickyShape.fold)
            .allowsHitTesting(false)
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(corner.gripPosition == .bottomRight || corner.gripPosition == .topLeft ? -45 : 45))
            .foregroundStyle(Color(nsColor: palette.faint))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { resized($0.translation) }
                .onEnded { _ in resizeEnded() })
            .cursor(.resize(corner.gripPosition))
            .help("Drag to resize")
            // The folded corner sits bottom right; keep the grip clear of it.
            .padding(corner.gripAlignment == .bottomTrailing ? StickyShape.fold * 0.4 : 0)
    }
}

/// A note shown formatted: bullets, numbers and checkboxes drawn, `**bold**` and `*italic*`
/// styled, never the raw markers. Click to type in it; click a checkbox to tick it.
struct NoteCard: View {
    let note: PhotoNote
    let font: NotesFont
    let palette: NotesPalette
    let edit: () -> Void
    let toggle: (Int) -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        let lines = NoteText.lines(note.text)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                lineView(line, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Menu {
                    Button("Edit Note") { edit() }  // not an action: one note in the panel, not a photo command
                    Button("Delete Note", role: .destructive) { delete() }  // not an action: one note in the panel
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Color(nsColor: palette.faint))
                .cursor(.link)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit Note") { edit() }  // not an action: one note in the panel, not a photo command
            Button("Delete Note", role: .destructive) { delete() }  // not an action: one note in the panel
        }
        .help("Click to edit")
    }

    @ViewBuilder private func lineView(_ line: NoteText.Line, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            switch line.marker {
            case .none:
                EmptyView()
            case .bullet:
                Text("•").font(font.font)
            case .numbered(let number):
                Text("\(number).").font(font.font).monospacedDigit()
            case .checkbox(let checked):
                Button { toggle(index) } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .cursor(.link)
                .help(checked ? "Untick" : "Tick")
            }
            Text(Self.inline(line.content.isEmpty ? " " : line.content))
                .font(font.font)
                .strikethrough(line.marker == .checkbox(checked: true), color: Color(nsColor: palette.faint))
                .opacity(line.marker == .checkbox(checked: true) ? 0.6 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
        }
        .foregroundStyle(Color(nsColor: palette.ink))
        .padding(.leading, CGFloat(line.indent) * 16)
    }

    /// Bold, italic and links in one line; anything else is shown as typed.
    static func inline(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
    }
}

/// A rectangle with its bottom-right corner folded over.
struct StickyShape: Shape {
    static let fold: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 4
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - Self.fold))
        path.addLine(to: CGPoint(x: rect.maxX - Self.fold, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The folded-over flap in the bottom-right corner.
private struct FoldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
