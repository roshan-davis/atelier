import CoreGraphics
import Foundation

/// How Cull picks the suggested keeper of each group (the Cull view's Pick By menu). Grouping
/// doesn't change with it.
public enum CullPick: String, CaseIterable, Identifiable, Sendable {
    /// Fewest closed eyes, sharp subject, good faces and exposure; Apple's aesthetics score
    /// breaks ties. The default.
    case balanced
    /// The sharpest subject: the faces (the eyes with Advanced checks on), else the main object.
    case sharpestSubject
    /// Fewest people with eyes closed, then half closed, then the sharpest.
    case eyesOpen
    /// The least clipped and closest to the group's usual brightness, then the sharpest.
    case bestExposure
    /// Eyes open and the most smiles, from MediaPipe Face Landmarker (needs the Advanced checks,
    /// which choosing it turns on), then the sharpest.
    case bestExpression
    /// Atelier's pick before Nov 2026: whole-frame sharpness plus the best face's quality.
    case classic

    public var id: String { rawValue }

    /// Needs the Advanced checks: expressions are read only there.
    public var needsAdvanced: Bool { self == .bestExpression }

    public var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .sharpestSubject: return "Sharpest Subject"
        case .eyesOpen: return "Everyone's Eyes Open"
        case .bestExposure: return "Best Exposure"
        case .bestExpression: return "Best Expression"
        case .classic: return "Classic"
        }
    }

    public var help: String {
        switch self {
        case .balanced: return "Fewest closed eyes, a sharp subject, good faces and exposure"
        case .sharpestSubject: return "The sharpest faces or main subject, whatever else"
        case .eyesOpen: return "The fewest people with eyes closed or half closed, then the sharpest"
        case .bestExposure: return "The least clipped, closest to the group's usual brightness, then the sharpest"
        case .bestExpression: return "Eyes open and the most smiles, then the sharpest (turns on Advanced checks)"
        case .classic: return "Atelier's earlier pick: the sharpest whole frame plus the best face"
        }
    }
}

/// One photo of a group measured against the rest of its group.
public struct CullAssessment: Sendable, Equatable {
    /// Faces found (background faces left out), and how many of them had their eyes judged.
    public var faces = 0
    /// Out-of-focus background faces left out of everything here (`CullBackground`).
    public var background = 0
    public var judged = 0
    public var closed = 0
    public var halfClosed = 0
    /// Subject sharpness against the group's sharpest (0...1).
    public var sharpness = 1.0
    /// `sharpness` was measured on the eyes from a large copy (Advanced checks, every photo of
    /// the group).
    public var onEyes = false
    /// What `sharpness` was measured on: the faces, or one region shared by the whole group.
    public var subject = CullSubject(kind: .wholeFrame)
    /// `subject` is one region every photo of the group was measured on (no faces in every shot).
    public var sharedRegion = false
    /// Stops brighter (positive) or darker than the group's middle photo.
    public var stops = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    /// The lowest face capture quality; nil without faces.
    public var worstFace: Double?
    public var coherence = 0.0
    public var aesthetics: Double?
    public var isUtility = false
    /// Faces with an expression read (Advanced checks), how many of them smile, and their mean
    /// smile score (0...1); nil without expressions.
    public var expressions = 0
    public var smiling = 0
    public var smile: Double?

    public init() {}

    var open: Int { judged - closed - halfClosed }

    /// Exposure trouble, 0 for none: stops away from the group (after a third of a stop) and
    /// clipped or crushed shares (after 1% and 5%).
    var exposurePenalty: Double {
        let clipped = max(0, highlights - 0.01) + max(0, shadows - 0.05)
        return max(0, abs(stops) - 0.33) + 10 * clipped
    }
}

extension Culling {
    /// Measures each photo of a group against the group: eyes per person, sharpness against the
    /// sharpest, exposure against the middle photo.
    /// Out-of-focus background faces are left out first (`CullBackground`): they aren't the
    /// subject, and their eyes and smiles don't count.
    public static func assess(_ all: [CullSignals]) -> [CullAssessment] {
        guard !all.isEmpty else { return [] }
        let allFaces: [[CullFace]] = all.map(\.faces)
        let background = Self.background(in: allFaces)
        let eyes = Self.eyes(in: allFaces, background: background)
        var group: [CullSignals] = []
        for index in all.indices { group.append(withoutBackground(all[index], background[index])) }
        // The eyes from the Advanced checks only when every photo has them: sizes differ.
        let eyeValues = group.map(\.eyeSharpness)
        let onEyes = eyeValues.allSatisfy { $0 != nil }
        let shared = onEyes ? nil : sharedSubject(group)
        let values: [Double]
        if onEyes {
            values = eyeValues.map { $0! }
        } else if let shared {
            values = group.map { $0.sharpnessGrid?.variance(in: shared.box) ?? $0.subjectSharpness }
        } else {
            values = group.map(\.subjectSharpness)
        }
        let best = max(values.max() ?? 0, .leastNonzeroMagnitude)
        let brightness = group.map(\.exposure.brightness).sorted()
        let middle = CullExposure(brightness: brightness[brightness.count / 2])
        return group.indices.map { index in
            let signal = group[index]
            var assessment = CullAssessment()
            assessment.faces = signal.faces.count
            assessment.background = background[index].filter { $0 }.count
            assessment.judged = eyes[index].filter { $0 != .unknown && $0 != .background }.count
            assessment.closed = eyes[index].filter { $0 == .closed }.count
            assessment.halfClosed = eyes[index].filter { $0 == .halfClosed }.count
            assessment.sharpness = values[index] / best
            assessment.onEyes = onEyes
            assessment.subject = shared ?? signal.subject
            assessment.sharedRegion = shared != nil
            assessment.stops = signal.exposure.stops(from: middle)
            assessment.highlights = signal.exposure.highlights
            assessment.shadows = signal.exposure.shadows
            assessment.worstFace = signal.faces.compactMap(\.quality).min()
            assessment.coherence = signal.coherence
            assessment.aesthetics = signal.aesthetics
            assessment.isUtility = signal.isUtility
            let smiles = signal.faces.compactMap { $0.expression?.smile }
            assessment.expressions = smiles.count
            assessment.smiling = smiles.filter { $0 >= CullEyes.smiling }.count
            assessment.smile = smiles.isEmpty ? nil : smiles.reduce(0, +) / Double(smiles.count)
            return assessment
        }
    }

    /// One region to measure every photo of a group on, when they aren't all measured on faces:
    /// the union of their subjects (people, main object), else the whole frame. Measuring each
    /// shot on its own main object compared different things (Rosh, Nov 14, 2026: near-identical
    /// shots called "Subject softer: 37%"). nil when every photo has faces (each face is read).
    static func sharedSubject(_ group: [CullSignals]) -> CullSubject? {
        guard group.count > 1, !group.allSatisfy({ $0.subject.kind == .faces }),
              group.allSatisfy({ $0.sharpnessGrid != nil }) else { return nil }
        // Plain loops: chained closures here were too slow for the type checker (Rosh's build).
        var union: CGRect? = nil
        var hasPeople = false
        for signal in group {
            let subject: CullSubject = signal.subject
            if subject.kind == .wholeFrame { continue }
            if subject.kind != .object { hasPeople = true }
            if let soFar = union {
                union = soFar.union(subject.box)
            } else {
                union = subject.box
            }
        }
        guard let box = union else { return CullSubject(kind: .wholeFrame) }
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let kind: CullSubject.Kind = hasPeople ? .people : .object
        return CullSubject(kind: kind, box: box.intersection(frame))
    }

    /// The photo to suggest keeping in a group, by `pick`.
    public static func keeper(_ group: [CullSignals], by pick: CullPick) -> Int? {
        guard !group.isEmpty else { return nil }
        if pick == .classic { return suggestedKeeper(group) }
        let scores = ranking(assess(group), by: pick)
        return scores.indices.max { scores[$0] < scores[$1] }
    }

    /// A score for each photo, higher is better, by `pick`.
    public static func ranking(_ assessments: [CullAssessment], by pick: CullPick) -> [Double] {
        let hasFaces = assessments.contains { $0.worstFace != nil }
        return assessments.map { (a: CullAssessment) -> Double in
            switch pick {
            case .balanced, .classic:
                // A blink costs more than a big drop in sharpness: a soft keeper can be sharpened
                // a little, a closed eye can't be opened.
                var score = a.sharpness
                if hasFaces { score += 0.5 * (a.worstFace ?? 0) }
                score -= 0.7 * Double(min(a.closed, 3))
                score -= 0.3 * Double(min(a.halfClosed, 3))
                score -= min(0.5, 0.25 * a.exposurePenalty)
                score += 0.1 * (a.aesthetics ?? 0)
                // Smiles only break near ties here; Best Expression weighs them properly.
                score += 0.1 * (a.smile ?? 0)
                if a.isUtility { score -= 0.5 }
                return score
            case .sharpestSubject:
                return a.sharpness + 0.01 * (a.aesthetics ?? 0)
            case .eyesOpen:
                let eyes: Double = -10 * Double(a.closed) - 3 * Double(a.halfClosed)
                return eyes + a.sharpness
            case .bestExposure:
                return -a.exposurePenalty + 0.2 * a.sharpness
            case .bestExpression:
                // Without the Advanced checks' expressions this is Everyone's Eyes Open.
                let eyes: Double = -10 * Double(a.closed) - 3 * Double(a.halfClosed)
                let smile: Double = 2 * (a.smile ?? 0)
                return eyes + smile + 0.3 * a.sharpness
            }
        }
    }

    // MARK: Words

    /// The focused photo's caption in the Cull view: "Sharpness 82% of the group's best · Eyes:
    /// 5 of 6 open, 1 closed · Exposure OK".
    public static func caption(_ a: CullAssessment, inGroup: Bool) -> String {
        var parts: [String] = []
        if inGroup {
            parts.append("\(a.onEyes ? "Eye sharpness" : "Sharpness") \(percent(a.sharpness)) of the group's best")
        }
        if a.faces > 0 {
            if a.judged == 0 {
                parts.append("Eyes: not checked (\(a.faces == 1 ? "face" : "faces") too small or turned)")
            } else {
                var eyes = "Eyes: \(a.open) of \(a.judged) open"
                if a.closed > 0 { eyes += ", \(a.closed) closed" }
                if a.halfClosed > 0 { eyes += ", \(a.halfClosed) half closed" }
                parts.append(eyes)
            }
            if a.expressions > 0 {
                parts.append(a.expressions == 1 ? (a.smiling == 1 ? "Smiling" : "Not smiling")
                                                : "Smiling: \(a.smiling) of \(a.expressions)")
            }
        }
        parts.append(exposureWords(a, inGroup: inGroup))
        return parts.joined(separator: " · ")
    }

    static func exposureWords(_ a: CullAssessment, inGroup: Bool) -> String {
        if a.highlights >= 0.02 { return "Highlights clipped: \(percent(a.highlights)) of the frame" }
        if a.shadows >= 0.05 { return "Shadows crushed: \(percent(a.shadows)) of the frame" }
        if inGroup, abs(a.stops) >= 0.5 { return "\(stopsWords(a.stops)) than the group's usual" }
        return "Exposure OK"
    }

    /// Why a photo wasn't kept, compared with its group's keeper: one line per measured
    /// difference, nothing that wasn't measured. Empty when nothing measured worse.
    public static func reasons(_ photo: CullAssessment, keeper: CullAssessment) -> [String] {
        var lines: [String] = []
        let people = { (n: Int, of: Int) -> String in of == 1 ? "" : ": \(n) of \(of) people" }
        if photo.closed > keeper.closed {
            lines.append("Eyes closed\(people(photo.closed, photo.judged))"
                         + (keeper.judged > 1 || photo.judged > 1 ? " (keeper: \(keeper.closed == 0 ? "none" : "\(keeper.closed)"))" : ""))
        }
        if photo.halfClosed > keeper.halfClosed {
            lines.append("Eyes half closed\(people(photo.halfClosed, photo.judged))")
        }
        if photo.expressions > 0, keeper.expressions > 0, photo.smiling < keeper.smiling {
            lines.append(photo.expressions == 1 ? "Not smiling (the keeper is)"
                         : "Fewer smiles: \(photo.smiling) of \(photo.expressions) people (keeper: \(keeper.smiling))")
        }
        if keeper.sharpness > 0, photo.sharpness < keeper.sharpness * 0.85 {
            let share = photo.sharpness / keeper.sharpness
            var line = "\(photo.onEyes ? "Eyes" : "Subject") softer: \(percent(share)) of the keeper's sharpness"
            if photo.coherence - keeper.coherence > 0.12 {
                line += ", looks like motion blur"
            } else if share < 0.6 {
                line += ", looks out of focus"
            }
            lines.append(line)
        }
        let difference = photo.stops - keeper.stops
        if abs(difference) >= 0.5 { lines.append("\(stopsWords(difference)) than the keeper") }
        if photo.highlights >= 0.02, photo.highlights > keeper.highlights * 2 {
            lines.append("Highlights clipped: \(percent(photo.highlights)) of the frame")
        }
        if photo.shadows >= 0.05, photo.shadows > keeper.shadows * 2 {
            lines.append("Shadows crushed: \(percent(photo.shadows)) of the frame")
        }
        if photo.closed <= keeper.closed, photo.halfClosed <= keeper.halfClosed,
           let mine = photo.worstFace, let theirs = keeper.worstFace, mine <= theirs - 0.15 {
            lines.append("Face quality lower: \(percent(mine)), keeper \(percent(theirs))")
        }
        if photo.isUtility, !keeper.isUtility { lines.append("Looks like a screenshot or document") }
        return lines
    }

    /// Where each photo's reason note is pinned (0...1 across and down the photo), or nil: the
    /// first face with eyes closed, else half closed, else (with fewer smiles than the keeper)
    /// the first face not smiling. Approximate, for the Cull preview's markers.
    public static func reasonSpots(_ group: [CullSignals], keeper: Int) -> [CGPoint?] {
        let eyes = Self.eyes(in: group.map(\.faces))
        // Background faces' smiles don't count (`CullBackground`).
        var smiles: [Int] = []
        for index in group.indices {
            var count = 0
            for (face, read) in zip(group[index].faces, eyes[index]) where read != .background {
                if (face.expression?.smile ?? 0) >= CullEyes.smiling { count += 1 }
            }
            smiles.append(count)
        }
        return group.indices.map { index in
            let faces = group[index].faces
            var notSmiling: Int? = nil
            for (position, face) in faces.enumerated() where eyes[index][position] != .background {
                if (face.expression?.smile ?? 1) < CullEyes.smiling {
                    notSmiling = position
                    break
                }
            }
            let pick = eyes[index].firstIndex(of: .closed) ?? eyes[index].firstIndex(of: .halfClosed)
                ?? (keeper < smiles.count && smiles[index] < smiles[keeper] ? notSmiling : nil)
            guard index != keeper, let pick, pick < faces.count else { return nil }
            let box = faces[pick].box
            return CGPoint(x: box.midX, y: 1 - box.midY)
        }
    }

    /// The Cull note for a photo not kept: a heading line, then a bullet per reason.
    public static func reasonNote(name keeperName: String, groupSize: Int, sameFrame: Bool, keeperChosenByYou: Bool,
                                  reasons: [String], droppedSuggestion: Bool) -> String {
        var lines = ["Not kept: group of \(groupSize) (\(sameFrame ? "Same frame" : "Similar shots")), keeper \(keeperName)"
                     + (keeperChosenByYou ? " (your pick)." : ".")]
        var bullets = reasons
        if droppedSuggestion { bullets.append("You dropped it (Atelier suggested keeping it)") }
        if bullets.isEmpty { bullets.append("Measured about as good as the keeper: a close call") }
        lines += bullets.map { "- " + $0 }
        return lines.joined(separator: "\n")
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func stopsWords(_ stops: Double) -> String {
        let amount = (abs(stops) * 10).rounded() / 10
        let number = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)
        return "\(number) stop\(amount == 1 ? "" : "s") \(stops < 0 ? "darker" : "brighter")"
    }
}
