import AtelierCore
import SwiftUI

/// One face as the Cull preview shows it: where it is and what culling concluded.
struct CullPreviewFace {
    /// Vision's rectangle (0...1, origin bottom left).
    let box: CGRect
    let eyes: CullEyes
    /// MediaPipe's smile score (Advanced checks), or nil.
    let smile: Double?
    /// Found by MediaPipe's face detector, not Apple Vision's.
    var byMediaPipe = false
}

/// What Cull measured on the focused photo, drawn on it for checking (Rosh, Nov 14, 2026: "when
/// it says subject, can it annotate on the preview of cull which one is picked as subject"): a
/// dashed orange box around the subject its sharpness was read on, and each face's box in the
/// color of its eyes (dashed when MediaPipe found it), with a smile mark. Text stays off the
/// photo: what the subject is and the legend are a line in the bar under it (`describe`), so
/// labels never pile up on a group shot (Rosh, Nov 14, 2026). Everything is cut to the photo.
/// Display only, like the note markers.
struct CullSubjectOverlay: View {
    @ObservedObject var frame: PhotoFrame
    let subject: CullSubject
    let faces: [CullPreviewFace]

    static let subjectColor = Color(red: 1, green: 0.62, blue: 0.1)

    var body: some View {
        GeometryReader { view in
            let visible = frame.rect.intersection(CGRect(origin: .zero, size: view.size))
            content(visible: visible)
                .clipShape(PhotoClip(rect: visible))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(visible rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                let placed = Self.place(subject.box, in: frame.rect).intersection(rect)
                if !placed.isNull {
                    // Inset by half the line so the dashes stay inside the photo.
                    let box = placed.insetBy(dx: 1, dy: 1)
                    Rectangle()
                        .stroke(Self.subjectColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: max(box.width, 0), height: max(box.height, 0))
                        .offset(x: box.minX, y: box.minY)
                }
                ForEach(faces.indices, id: \.self) { index in
                    faceMark(faces[index])
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func faceMark(_ face: CullPreviewFace) -> some View {
        let box = Self.place(face.box, in: frame.rect)
        let color = Self.color(face.eyes)
        let dash: [CGFloat] = face.byMediaPipe ? [3, 2] : []
        Rectangle()
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dash))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
        if let smile = face.smile, smile >= CullEyes.smiling {
            Image(systemName: "face.smiling")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .padding(1)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .offset(x: box.maxX - 6, y: box.maxY - 6)
        }
    }

    /// The line under the photo: what the subject is, and how to read the boxes.
    static func describe(subject: CullSubject, sharedRegion: Bool, faceCount: Int) -> String {
        var what: String
        switch subject.kind {
        case .faces: what = faceCount == 1 ? "the face" : "\(faceCount) faces"
        case .people: what = "the people (no face found)"
        case .object: what = "Vision's main object"
        case .wholeFrame: what = "the whole frame (nothing stood out)"
        }
        if sharedRegion && subject.kind != .wholeFrame { what += ", same area in every shot" }
        return "Subject (orange): \(what)"
    }

    /// How the face boxes are colored, for the bar's tooltip.
    static let legend = "Face boxes: green eyes open, yellow half closed, red closed, gray not checked; "
        + "dashed when MediaPipe found the face; a smile mark when smiling (Advanced checks)."

    static func color(_ eyes: CullEyes) -> Color {
        switch eyes {
        case .open: return .green
        case .halfClosed: return .yellow
        case .closed: return .red
        case .unknown: return .gray
        }
    }

    /// A Vision rectangle in the view's top-left points, given where the photo is.
    static func place(_ box: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + box.minX * rect.width, y: rect.minY + (1 - box.maxY) * rect.height,
               width: box.width * rect.width, height: box.height * rect.height)
    }
}

/// Clips an overlay to the photo's visible rectangle (view coordinates), so nothing drawn on a
/// photo reaches the bars or the letterbox around it.
struct PhotoClip: Shape {
    var rect: CGRect

    func path(in _: CGRect) -> Path {
        rect.isNull ? Path() : Path(rect)
    }
}
