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
/// color of its eyes (dashed when MediaPipe found it) with a small number. Text stays off the
/// photo: what the subject is and what each number means are lines in the bar under it
/// (`describe`, `legend`), so labels never pile up on a group shot (Rosh, Nov 14, 2026: "a small
/// circled number and at the bottom the text associated"). Everything is cut to the photo.
/// Display only, like the note markers.
struct CullSubjectOverlay: View {
    /// Kept so the overlay redraws when the photo's size changes.
    @ObservedObject var frame: PhotoFrame
    let subject: CullSubject
    let faces: [CullPreviewFace]

    static let subjectColor = Color(red: 1, green: 0.62, blue: 0.1)

    var body: some View {
        // The overlay's host is the photo itself (ZoomScrollView moves and clips it), so the
        // photo is this view's own size: no PhotoFrame timing involved.
        GeometryReader { view in
            let photo = CGRect(origin: .zero, size: view.size)
            content(photo: photo)
                .clipShape(PhotoClip(rect: photo))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(photo rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if rect.width > 0, rect.height > 0 {
                let placed = Self.place(subject.box, in: rect).intersection(rect)
                if !placed.isNull {
                    // Inset by half the line so the dashes stay inside the photo.
                    let box = placed.insetBy(dx: 1, dy: 1)
                    Rectangle()
                        .stroke(Self.subjectColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: max(box.width, 0), height: max(box.height, 0))
                        .offset(x: box.minX, y: box.minY)
                }
                ForEach(faces.indices, id: \.self) { index in
                    faceMark(faces[index], number: index + 1, photo: rect)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func faceMark(_ face: CullPreviewFace, number: Int, photo: CGRect) -> some View {
        let box = Self.place(face.box, in: photo)
        let color = Self.color(face.eyes)
        let dash: [CGFloat] = Self.dash(face)
        Rectangle()
            .stroke(color, style: StrokeStyle(lineWidth: face.eyes == .background ? 1 : 1.5, dash: dash))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
        // The face's number on its top left corner; what it means is in the bar below.
        FaceNumberBadge(number: number, color: color)
            .offset(x: box.minX - 8, y: box.minY - 8)
    }

    /// What each face's number means, for the line under the photo: "Eyes open, smiling".
    static func words(_ face: CullPreviewFace) -> String {
        var text: String
        switch face.eyes {
        case .open: text = "Eyes open"
        case .halfClosed: text = "Half closed"
        case .closed: text = "Eyes closed"
        case .unknown: text = "Not checked"
        case .background: return "Background, out of focus: left out"
        }
        if let smile = face.smile { text += smile >= CullEyes.smiling ? ", smiling" : ", not smiling" }
        if face.byMediaPipe { text += ", found by MediaPipe" }
        return text
    }

    /// "① Eyes open, smiling  ② Half closed", each number in its face's color.
    static func legend(_ faces: [CullPreviewFace]) -> Text {
        var line = Text("")
        for (index, face) in faces.enumerated() {
            let gap: String = index == 0 ? "" : "   "
            let number: Text = Text(circled(index + 1)).foregroundColor(color(face.eyes)).bold()
            let meaning: Text = Text(" " + words(face))
            line = line + Text(gap)
            line = line + number
            line = line + meaning
        }
        return line
    }

    /// ①…⑳, then (21) and on.
    static func circled(_ number: Int) -> String {
        guard (1...20).contains(number), let scalar = Unicode.Scalar(0x2460 + number - 1) else { return "(\(number))" }
        return String(Character(scalar))
    }

    /// The line under the photo: what the subject is, and how to read the boxes.
    static func describe(subject: CullSubject, sharedRegion: Bool, faceCount: Int, background: Int = 0) -> String {
        var what: String
        switch subject.kind {
        case .faces: what = faceCount == 1 ? "the face" : "\(faceCount) faces"
        case .people: what = "the people (no face found)"
        case .object: what = "Vision's main object"
        case .wholeFrame: what = "the whole frame (nothing stood out)"
        }
        if sharedRegion && subject.kind != .wholeFrame { what += ", same area in every shot" }
        if background > 0 {
            what += background == 1 ? " · 1 blurred background face left out" : " · \(background) blurred background faces left out"
        }
        return "Subject (orange): \(what)"
    }

    /// How the face boxes are colored, for the bar's tooltip.
    static let colorKey = "Face boxes: green eyes open, yellow half closed, red closed, gray not checked; "
        + "dashed when MediaPipe found the face. Faint dotted boxes are out-of-focus faces in the background, "
        + "left out of the subject, the eye checks and the reasons. Each face's number is explained in the line below."

    static func color(_ eyes: CullEyes) -> Color {
        switch eyes {
        case .open: return .green
        case .halfClosed: return .yellow
        case .closed: return .red
        case .unknown: return .gray
        case .background: return backgroundColor
        }
    }

    /// Out-of-focus background faces: faint, so the eye colors stand out.
    static let backgroundColor = Color(white: 0.85).opacity(0.55)

    /// Background faces dotted, MediaPipe's dashed, Apple Vision's solid.
    static func dash(_ face: CullPreviewFace) -> [CGFloat] {
        if face.eyes == .background { return [1.5, 3] }
        return face.byMediaPipe ? [3, 2] : []
    }

    /// A Vision rectangle in the view's top-left points, given where the photo is.
    static func place(_ box: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + box.minX * rect.width, y: rect.minY + (1 - box.maxY) * rect.height,
               width: box.width * rect.width, height: box.height * rect.height)
    }
}

/// A face's number on the Cull preview: a small disc in the color of its eyes.
struct FaceNumberBadge: View {
    let number: Int
    let color: Color

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 16, height: 16)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
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
