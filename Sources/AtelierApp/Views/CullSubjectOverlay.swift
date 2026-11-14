import AtelierCore
import SwiftUI

/// One face as the Cull preview shows it: where it is and what culling concluded.
struct CullPreviewFace {
    /// Vision's rectangle (0...1, origin bottom left).
    let box: CGRect
    let eyes: CullEyes
    /// MediaPipe's smile score (Advanced checks), or nil.
    let smile: Double?
}

/// What Cull measured on the focused photo, drawn on it for checking (Rosh, Nov 14, 2026: "when
/// it says subject, can it annotate on the preview of cull which one is picked as subject"): a
/// dashed box around the subject its sharpness was read on, with what it is and the sharpness
/// against the group's best, and each face with its eyes. Display only, like the note markers.
struct CullSubjectOverlay: View {
    @ObservedObject var frame: PhotoFrame
    let subject: CullSubject
    /// Every photo of the group was measured on this same region.
    var sharedRegion = false
    let faces: [CullPreviewFace]
    /// "Sharpness 82% of the group's best", or nil for a photo on its own.
    let sharpness: String?

    private let subjectColor = Color(red: 1, green: 0.62, blue: 0.1)

    var body: some View {
        GeometryReader { view in
            content(visible: frame.rect.intersection(CGRect(origin: .zero, size: view.size)))
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// `visible` is the part of the photo on screen: boxes are cut to it, so nothing is drawn
    /// past the photo onto the bars (Rosh, Nov 14, 2026).
    @ViewBuilder
    private func content(visible rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                ForEach(faces.indices, id: \.self) { index in
                    let face = faces[index]
                    let box = Self.place(face.box, in: frame.rect).intersection(rect)
                    if !box.isNull {
                        Rectangle()
                            .stroke(color(face.eyes), lineWidth: 1.5)
                            .frame(width: box.width, height: box.height)
                            .offset(x: box.minX, y: box.minY)
                        tag(words(face), color: color(face.eyes))
                            .offset(x: box.minX, y: min(box.maxY + 3, rect.maxY - 20))
                    }
                }
                let placed = Self.place(subject.box, in: frame.rect).intersection(rect)
                if !placed.isNull {
                    // Inset by half the line so the dashes stay inside the photo.
                    let box = placed.insetBy(dx: 1, dy: 1)
                    Rectangle()
                        .stroke(subjectColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: max(box.width, 0), height: max(box.height, 0))
                        .offset(x: box.minX, y: box.minY)
                    // Inside the box's top left corner, so it never leaves the photo.
                    tag(title, color: subjectColor)
                        .offset(x: box.minX + 4, y: box.minY + 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        var what: String
        switch subject.kind {
        case .faces: what = faces.count == 1 ? "Subject: the face" : "Subject: \(faces.count) faces"
        case .people: what = "Subject: the people (no face found)"
        case .object: what = "Subject: Vision's main object"
        case .wholeFrame: what = "Subject: whole frame (nothing stood out)"
        }
        if sharedRegion && subject.kind != .wholeFrame { what += ", same area in every shot" }
        return [what, sharpness].compactMap { $0 }.joined(separator: " · ")
    }

    private func words(_ face: CullPreviewFace) -> String {
        var text: String
        switch face.eyes {
        case .open: text = "Eyes open"
        case .halfClosed: text = "Half closed"
        case .closed: text = "Eyes closed"
        case .unknown: text = "Not checked"
        }
        if let smile = face.smile { text += smile >= CullEyes.smiling ? " · smiling" : " · not smiling" }
        return text
    }

    private func color(_ eyes: CullEyes) -> Color {
        switch eyes {
        case .open: return .green
        case .halfClosed: return .yellow
        case .closed: return .red
        case .unknown: return .gray
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.9), lineWidth: 1))
    }

    /// A Vision rectangle in the view's top-left points, given where the photo is.
    static func place(_ box: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + box.minX * rect.width, y: rect.minY + (1 - box.maxY) * rect.height,
               width: box.width * rect.width, height: box.height * rect.height)
    }
}
