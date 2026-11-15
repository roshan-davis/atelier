import CoreGraphics
import Foundation

/// Faces in the out-of-focus background: much softer than the sharpest face in the same frame.
/// The photographer focused on what the photo is of, so these aren't the subject: Cull leaves
/// them out of the subject, the eye checks, the smiles and the reasons (Rosh, Nov 14, 2026: a
/// blurred passer-by behind him read as "Eyes half closed: 1 of 2 people").
///
/// Sharpness is the variance of the Laplacian inside each face box at the standard 1024 px size
/// (`CullFace.sharpness`). Measured on Nov 14, 2026, as a share of the sharpest face in the frame:
/// - Faces in focus: 0.41 to 1 (group-5-outdoor 0.41 to 1, kids-group 0.65 to 1, crowd 0.44 to 1,
///   profile 0.69 to 1). Smooth skin reads lower than lined or bearded skin, hence 0.41.
/// - Background faces: 0.002 for the passer-by in Rosh's Z62_9227 (measured from the Cull
///   preview), 0.065 to 0.24 for the café behind the couple in profile.jpg.
/// `softer` sits halfway (in stops of blur) between the two; the one background face above it
/// (0.24) is under a third of the sharp face's width, which `smallSofter` catches.
public enum CullBackground {
    /// A face with less than this share of the sharpest face's sharpness is background.
    public static let softer = 0.2
    /// A face this soft is background when it is also at most `smallWidth` of the sharpest
    /// face's width (farther away).
    public static let smallSofter = 0.35
    public static let smallWidth = 0.5

    /// Background faces of one photo, judged on that photo alone.
    public static func inFrame(_ faces: [CullFace]) -> [Bool] {
        var reference: CullFace?
        for face in faces {
            guard let sharpness = face.sharpness else { continue }
            if sharpness > (reference?.sharpness ?? 0) { reference = face }
        }
        guard let reference, let best = reference.sharpness, best > 0, reference.box.width > 0 else {
            return [Bool](repeating: false, count: faces.count)
        }
        var result: [Bool] = []
        for face in faces {
            guard let sharpness = face.sharpness else {
                result.append(false)
                continue
            }
            let share = sharpness / best
            let width = Double(face.box.width / reference.box.width)
            result.append(share < softer || (share < smallSofter && width <= smallWidth))
        }
        return result
    }
}

extension Culling {
    /// Background faces in each photo of a group (`CullBackground`). One soft shot doesn't make
    /// a person background, nor one shot where focus slipped to them make them the subject: a
    /// person (matched across the group by position, `people(in:)`) is background when they read
    /// as background in more than half the shots they are in. A missed-focus shot then still has
    /// its real subject, now soft, and is picked against as it should be.
    public static func background(in faces: [[CullFace]]) -> [[Bool]] {
        var frames: [[Bool]] = []
        for photoFaces in faces { frames.append(CullBackground.inFrame(photoFaces)) }
        guard faces.count > 1 else { return frames }
        let people = Self.people(in: faces)
        var soft: [Int: Int] = [:]
        var seen: [Int: Int] = [:]
        for photo in faces.indices {
            for index in faces[photo].indices {
                let person = people[photo][index]
                seen[person, default: 0] += 1
                if frames[photo][index] { soft[person, default: 0] += 1 }
            }
        }
        var result: [[Bool]] = []
        for photo in faces.indices {
            var row: [Bool] = []
            for index in faces[photo].indices {
                let person = people[photo][index]
                row.append(2 * soft[person, default: 0] > seen[person, default: 0])
            }
            result.append(row)
        }
        return result
    }

    /// `signals` without its background faces (`isBackground`, one per face), with the subject
    /// and its sharpness worked out again from the faces left: around them, else around the
    /// people Vision found, else the whole frame. Unchanged when no face is background.
    static func withoutBackground(_ signals: CullSignals, _ isBackground: [Bool]) -> CullSignals {
        guard isBackground.contains(true), isBackground.count == signals.faces.count else { return signals }
        var result = signals
        var kept: [CullFace] = []
        for (face, background) in zip(signals.faces, isBackground) where !background { kept.append(face) }
        result.faces = kept
        result.faceQuality = kept.compactMap(\.quality).max()
        let subject = Self.subject(faces: kept, people: signals.people, saliency: nil, planeWidth: signals.planeWidth)
        result.subject = subject
        let region: Double = signals.sharpnessGrid?.variance(in: subject.box) ?? signals.sharpness
        result.subjectSharpness = subject.kind == .faces ? subjectSharpness(faces: kept, fallback: region) : region
        return result
    }
}
