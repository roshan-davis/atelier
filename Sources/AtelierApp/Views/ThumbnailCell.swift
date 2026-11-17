import AppKit
import AtelierCore
import SwiftUI

/// How a thumbnail reads: the photo being worked on, the rest of the selection, or neither.
/// Every view with selectable thumbnails (grid, Filmstrip, Cull) draws these the same way, so
/// the focused photo stands out from a multiple selection in every theme.
enum ThumbnailState {
    case unselected, selected, focused

    init(isFocused: Bool, isSelected: Bool) {
        self = isFocused ? .focused : (isSelected ? .selected : .unselected)
    }

    static let cornerRadius: CGFloat = 5

    var borderWidth: CGFloat {
        switch self {
        case .unselected: return 1
        case .selected: return 1.5
        case .focused: return 2.5
        }
    }

    var borderColor: NSColor {
        switch self {
        case .unselected: return NSColor.secondaryLabelColor.withAlphaComponent(0.18)
        case .selected: return NSColor.controlAccentColor.withAlphaComponent(0.65)
        case .focused: return .controlAccentColor
        }
    }

    var fill: NSColor {
        switch self {
        case .unselected: return NSColor.labelColor.withAlphaComponent(0.04)
        case .selected: return NSColor.controlAccentColor.withAlphaComponent(0.2)
        case .focused: return NSColor.controlAccentColor.withAlphaComponent(0.3)
        }
    }

    /// The thin white line inside the focused photo's ring, so the ring shows on black
    /// (Darkroom) and on light gray (Light) alike.
    static let keyline = NSColor.white.withAlphaComponent(0.9)

    /// Rejected photos are dimmed in every view.
    static let rejectedOpacity = 0.4
}

extension View {
    /// The background tint and ring for a thumbnail in `state`.
    func thumbnailFrame(_ state: ThumbnailState, cornerRadius: CGFloat = ThumbnailState.cornerRadius) -> some View {
        modifier(ThumbnailFrame(state: state, cornerRadius: cornerRadius))
    }
}

private struct ThumbnailFrame: ViewModifier {
    let state: ThumbnailState
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: state.fill), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: state.borderColor), lineWidth: state.borderWidth)
                if state == .focused {
                    RoundedRectangle(cornerRadius: max(0, cornerRadius - state.borderWidth))
                        .strokeBorder(Color(nsColor: ThumbnailState.keyline), lineWidth: 1)
                        .padding(state.borderWidth)
                }
            }
    }
}

/// A small dark pill for badges drawn on a photo; readable on light and dark pictures alike.
struct OverlayPill<Content: View>: View {
    private let tint: Color
    private let content: Content

    init(tint: Color = .white, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 3) { content }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 3.5))
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .fixedSize()
    }
}

/// The badges in a thumbnail's four corners, as in Lightroom Classic's grid cells:
/// - top left: the photo's number in the Filmstrip, and its flag;
/// - top right: stack, virtual copy, AI or Edit In version, RAW+JPEG pair, cull group;
/// - bottom left: stars and color label;
/// - bottom right: has Develop edits, cropped, has masks, original offline.
/// Used by the grid and the Filmstrip; the Cull view uses the same pill and ring.
struct ThumbnailBadges: View {
    let row: AssetRow
    /// The thumbnail's size in points, which decides how much is spelled out.
    let size: CGSize
    /// The photo's place in the strip, 1-based; nil hides it.
    var index: Int?
    /// The focused photo's number sits on an accent-colored circle.
    var isFocused = false

    enum Density {
        /// Flag, label dot, "★ 3" and one edit or offline mark.
        case compact
        /// Every badge, stack and pair badges as icons with numbers, "★ 3".
        case small
        /// Every badge, with names ("Copy 1", "RAW+JPG") and a row of stars.
        case regular

        init(size: CGSize) {
            if min(size.width, size.height) < ThumbnailBadges.compactSize {
                self = .compact
            } else {
                self = size.width < 120 ? .small : .regular
            }
        }
    }

    /// Below this height or width (the Filmstrip dragged to its smallest) only the essentials show.
    nonisolated static let compactSize: CGFloat = 64

    private var density: Density { Density(size: size) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                topLeading
                Spacer(minLength: 0)
                if density != .compact { topTrailing }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 2) {
                bottomLeading
                Spacer(minLength: 0)
                bottomTrailing
            }
        }
        .padding(density == .compact ? 3 : 4)
        .allowsHitTesting(false)
    }

    // MARK: Corners

    @ViewBuilder private var topLeading: some View {
        HStack(spacing: 3) {
            if density != .compact, let index {
                Text("\(index)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, index > 9 ? 3 : 0)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(isFocused ? Color.accentColor : Color.black.opacity(0.6), in: Capsule())
                    .fixedSize()
            }
            switch row.flag {
            case .picked: OverlayPill { Image(systemName: "flag.fill") }
            case .rejected:
                OverlayPill(tint: Color(nsColor: .systemRed)) { Image(systemName: "xmark.circle.fill") }
            case .none: EmptyView()
            }
        }
    }

    @ViewBuilder private var topTrailing: some View {
        let items = Self.groupBadges(for: row)
        if !items.isEmpty {
            OverlayPill {
                ForEach(items.indices, id: \.self) { position in
                    let item = items[position]
                    HStack(spacing: 2) {
                        if let symbol = item.symbol { Image(systemName: symbol) }
                        if let text = density == .regular ? item.text : item.shortText { Text(text).monospaced() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var bottomLeading: some View {
        HStack(spacing: 3) {
            if row.rating > 0 {
                // Gold stars straight on the photo, with a shadow so they read on light pictures.
                HStack(spacing: 1) {
                    if density == .regular {
                        ForEach(0..<min(row.rating, 5), id: \.self) { _ in Image(systemName: "star.fill") }
                    } else {
                        Image(systemName: "star.fill")
                        Text("\(row.rating)").monospacedDigit()
                    }
                }
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Self.gold)
                .shadow(color: .black.opacity(0.9), radius: 1.5)
                .fixedSize()
            }
            if let label = row.colorLabel {
                Circle()
                    .fill(Color(nsColor: ThumbnailItem.color(for: label)))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 1))
            }
        }
    }

    @ViewBuilder private var bottomTrailing: some View {
        let marks = density == .compact ? Array(Self.statusMarks(for: row).suffix(1)) : Self.statusMarks(for: row)
        if !marks.isEmpty {
            OverlayPill {
                ForEach(marks, id: \.symbol) { mark in
                    Image(systemName: mark.symbol).foregroundStyle(mark.color.map { Color(nsColor: $0) } ?? Color.white.opacity(0.9))
                }
            }
        }
    }

    // MARK: Content

    static let gold = Color(red: 1, green: 0.84, blue: 0.04)

    struct GroupBadge: Equatable {
        /// Nil shows the text alone.
        var symbol: String?
        /// Spelled out on large thumbnails.
        var text: String?
        /// On smaller thumbnails; nil shows the icon alone.
        var shortText: String?
    }

    /// What group the photo belongs to, most important first.
    static func groupBadges(for row: AssetRow) -> [GroupBadge] {
        var badges: [GroupBadge] = []
        switch row.stackKind {
        case .virtualCopy?: badges.append(GroupBadge(symbol: "doc.on.doc", text: row.stackName ?? "Copy", shortText: nil))
        case .ai?: badges.append(GroupBadge(symbol: "sparkles", text: row.stackName ?? "AI", shortText: nil))
        case .externalEdit? where row.stackName == LensBlurPhoto.versionName:
            badges.append(GroupBadge(symbol: "camera.aperture", text: "Lens Blur", shortText: nil))
        case .externalEdit?: badges.append(GroupBadge(symbol: "square.split.bottomrightquarter", text: "Edit", shortText: nil))
        default:
            // An original with versions stacked on it: how many photos the stack holds.
            if let count = row.stackCount, count > 0 {
                badges.append(GroupBadge(symbol: "rectangle.stack.fill", text: "\(count + 1)", shortText: "\(count + 1)"))
            }
        }
        if let formats = row.pairedFormats {
            // Text only, as in the design: an icon on every photo of a RAW+JPEG shoot is noise.
            badges.append(GroupBadge(symbol: nil, text: "RAW+" + formats.replacingOccurrences(of: ",", with: "+"),
                                     shortText: "RAW+" + formats.replacingOccurrences(of: ",", with: "+")))
        }
        if let size = row.cullGroupSize, size > 1 {
            badges.append(GroupBadge(symbol: "square.on.square", text: "\(size)", shortText: "\(size)"))
        }
        return badges
    }

    struct StatusMark: Equatable {
        var symbol: String
        /// Nil draws it white.
        var color: NSColor?
        var description: String
    }

    /// The bottom-right marks, least important first: on the smallest thumbnails only the last
    /// one shows, so an offline original always wins.
    static func statusMarks(for row: AssetRow) -> [StatusMark] {
        var marks: [StatusMark] = []
        if row.hasEdits { marks.append(StatusMark(symbol: "slider.horizontal.3", description: "Edited in Develop")) }
        if row.isCropped { marks.append(StatusMark(symbol: "crop", description: "Cropped")) }
        if row.hasMasks { marks.append(StatusMark(symbol: "circle.dashed", description: "Has masks")) }
        if row.hasNotes { marks.append(StatusMark(symbol: "note.text", color: .systemYellow, description: "Has notes")) }
        if row.isOffline {
            marks.append(StatusMark(symbol: "exclamationmark.triangle.fill", color: .systemOrange,
                                    description: "Original is offline"))
        }
        return marks
    }

    /// The thumbnail's tooltip: the file name and what its badges mean.
    static func help(for row: AssetRow) -> String {
        var parts = [row.filename]
        if let name = row.stackName { parts.append(name) }
        if let formats = row.pairedFormats { parts.append("RAW+" + formats.replacingOccurrences(of: ",", with: "+")) }
        parts += statusMarks(for: row).map(\.description)
        return parts.joined(separator: " · ")
    }
}
