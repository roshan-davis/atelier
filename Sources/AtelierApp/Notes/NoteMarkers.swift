import AppKit
import AtelierCore
import SwiftUI

/// A note's numbered marker: the number in a disc the color of the notes' paper.
struct NoteMarkerBadge: View {
    let number: Int
    var size: CGFloat = 22
    @AppStorage(NotesPanel.colorKey) private var color: NoteColor = .yellow
    @AppStorage(NotesPanel.customColorKey) private var customHex = "FFEB6B"

    var body: some View {
        let palette = NotesPalette(color: color, customHex: customHex, opacity: 1)
        Text("\(number)")
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(Color(nsColor: palette.ink))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(nsColor: palette.paper)))
            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
    }
}

/// The Cull preview's note markers (Rosh, Nov 14, 2026): each note pinned to a spot shows its
/// number there with the note's first words beside it, following the photo as it zooms and
/// scrolls. Display only: clicks go to the photo underneath (zoom, pan, placing a pin).
struct NoteMarkersOverlay: View {
    @ObservedObject var notes: PhotoNotesModel
    @ObservedObject var frame: PhotoFrame
    /// Room for a label, in points; markers near the right edge put it on their left.
    private let labelWidth: CGFloat = 220

    var body: some View {
        let written = notes.notes.filter { !NoteText.cleaned($0.text).isEmpty }
        let numbers = NotePins.numbers(written)
        let rect = frame.rect
        ZStack(alignment: .topLeading) {
            Color.clear
            if rect.width > 0 {
                ForEach(written.filter { $0.spot != nil }, id: \.id) { note in
                    let spot = note.spot!
                    let point = CGPoint(x: rect.minX + spot.x * rect.width, y: rect.minY + spot.y * rect.height)
                    marker(note, number: numbers[note.id ?? -1] ?? 0, leftLabel: point.x + labelWidth > rect.maxX)
                        .fixedSize()
                        .alignmentGuide(.leading) { d in d[HorizontalAlignment.center] - point.x }
                        .alignmentGuide(.top) { d in d[VerticalAlignment.center] - point.y }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    /// The badge with the label beside it. Laid out so the badge's center is the view's center.
    private func marker(_ note: PhotoNote, number: Int, leftLabel: Bool) -> some View {
        let label = Text(Self.summary(note))
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.6)))
        return HStack(spacing: 4) {
            label.opacity(leftLabel ? 1 : 0)
            NoteMarkerBadge(number: number)
            label.opacity(leftLabel ? 0 : 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }

    /// A note's first words for its marker: for Cull's reasons, the first reason, not the heading.
    static func summary(_ note: PhotoNote) -> String {
        let line = firstLine(note)
        return line.count > 42 ? String(line.prefix(40)) + "…" : line
    }

    private static func firstLine(_ note: PhotoNote) -> String {
        let lines = NoteText.plain(note.text).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if note.source == .cull, lines.count > 1 {
            let reasons = lines.dropFirst().filter { !$0.hasPrefix("Kept later") }
            return reasons.first ?? lines[0]
        }
        return lines.first ?? ""
    }
}
