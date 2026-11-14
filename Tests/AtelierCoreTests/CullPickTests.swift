import CoreGraphics
import Foundation
import XCTest
@testable import AtelierCore

/// Pick By: eyes per person, sharpness on the subject, exposure, and the reasons Cull writes.
final class CullPickTests: XCTestCase {
    // MARK: Eyes

    func testEyeOpennessFromAnOutline() throws {
        // An eye 30 px wide and 9 px tall, tilted: openness 0.3 whatever the tilt.
        let angle = 0.3
        let outline = [(-15.0, 0.0), (-8, 4.5), (0, 4.5), (8, 4.5), (15, 0), (8, -4.5), (0, -4.5), (-8, -4.5)].map { x, y in
            CGPoint(x: 100 + x * cos(angle) - y * sin(angle), y: 50 + x * sin(angle) + y * cos(angle))
        }
        let read = try XCTUnwrap(CullFaceReading.openness(of: outline))
        XCTAssertEqual(read.openness, 0.3, accuracy: 0.01)
        XCTAssertEqual(read.width, 30, accuracy: 0.01)
        let closed = outline.map { CGPoint(x: $0.x, y: 50 + ($0.y - 50) * 0.15) }
        XCTAssertLessThan(try XCTUnwrap(CullFaceReading.openness(of: closed)).openness, 0.15)
        XCTAssertNil(CullFaceReading.openness(of: Array(outline.prefix(3))))
    }

    /// A face at `x` across the frame with eyes `openness` open.
    private func face(_ x: Double, _ openness: Double?, quality: Double = 0.6, skip: CullFaceSkip? = nil) -> CullFace {
        CullFace(box: CGRect(x: x, y: 0.5, width: 0.1, height: 0.15), quality: quality, openness: openness, skip: skip,
                 sharpness: 100)
    }

    func testEachPersonIsComparedWithThemselves() {
        // Three people over three shots: the first blinks in shot 2, the second has narrow eyes
        // all along (never "closed"), the third half closes them in shot 3.
        let faces: [[CullFace]] = [
            [face(0.1, 0.30), face(0.4, 0.14), face(0.7, 0.28)],
            [face(0.11, 0.06), face(0.41, 0.13), face(0.69, 0.29)],
            [face(0.1, 0.31), face(0.4, 0.14), face(0.7, 0.18)],
        ]
        XCTAssertEqual(Culling.people(in: faces), [[0, 1, 2], [0, 1, 2], [0, 1, 2]])
        XCTAssertEqual(Culling.eyes(in: faces), [
            [.open, .open, .open],
            [.closed, .open, .open],
            [.open, .open, .halfClosed],
        ])
        // A squint at 60% of the person's widest reads half closed, never closed.
        XCTAssertEqual(Culling.eyes(in: [[face(0.1, 0.30)], [face(0.1, 0.18)]]), [[.open], [.halfClosed]])
        // Sunglasses or a face that wasn't judged: unknown, never closed.
        XCTAssertEqual(Culling.eyes(in: [[face(0.1, nil, skip: .small)], [face(0.1, 0.12)]]), [[.unknown], [.open]])
    }

    /// With Advanced checks, MediaPipe's blink score decides, each person against their own
    /// lowest (values from Rosh's group test photo: 0.15 open, 0.6 blinking, 0.33 half closed).
    func testBlinkScoresDecideWhenRead() {
        func blinking(_ x: Double, _ blink: Double, smile: Double = 0.8) -> CullFace {
            var f = face(x, 0.3)
            f.expression = FaceExpression(blinkLeft: blink, blinkRight: blink, smileLeft: smile, smileRight: smile)
            return f
        }
        let faces: [[CullFace]] = [
            [blinking(0.1, 0.20), blinking(0.4, 0.15), blinking(0.7, 0.28)],
            [blinking(0.1, 0.33), blinking(0.4, 0.61), blinking(0.7, 0.30)],
        ]
        XCTAssertEqual(Culling.eyes(in: faces), [[.open, .open, .open], [.halfClosed, .closed, .open]])
        // On its own a photo has nothing to compare with: only a clear blink counts.
        XCTAssertEqual(Culling.eyes(in: [[blinking(0.1, 0.55), blinking(0.4, 0.77)]]), [[.open, .closed]])
        // The outline reads closed (0.06), but the blink score wins where it was read.
        var open = blinking(0.1, 0.12)
        open.openness = 0.06
        XCTAssertEqual(Culling.eyes(in: [[open]]), [[.open]])
    }

    func testBestExpressionPrefersSmilesWithEyesOpen() {
        func person(_ x: Double, blink: Double, smile: Double) -> CullFace {
            var f = face(x, 0.3)
            f.expression = FaceExpression(blinkLeft: blink, blinkRight: blink, smileLeft: smile, smileRight: smile)
            return f
        }
        let serious = photo(faces: [person(0.2, blink: 0.1, smile: 0.1), person(0.6, blink: 0.1, smile: 0.2)], sharpness: 120)
        let smiling = photo(faces: [person(0.2, blink: 0.1, smile: 0.9), person(0.6, blink: 0.12, smile: 0.85)], sharpness: 100)
        let blinkingSmile = photo(faces: [person(0.2, blink: 0.7, smile: 0.95), person(0.6, blink: 0.1, smile: 0.9)], sharpness: 130)
        XCTAssertEqual(Culling.keeper([serious, smiling, blinkingSmile], by: .bestExpression), 1)
        XCTAssertTrue(CullPick.bestExpression.needsAdvanced)
        let a = Culling.assess([serious, smiling])
        XCTAssertEqual(a[1].smiling, 2)
        XCTAssertEqual(Culling.reasons(a[0], keeper: a[1]).first, "Fewer smiles: 0 of 2 people (keeper: 2)")
        XCTAssertTrue(Culling.caption(a[1], inGroup: true).contains("Smiling: 2 of 2"))
    }

    func testReasonNotesArePinnedToTheFaceWithClosedEyes() {
        let keeper = photo(faces: [face(0.1, 0.30), face(0.5, 0.29)])
        let blink = photo(faces: [face(0.1, 0.31), face(0.5, 0.05)])
        let soft = photo(faces: [face(0.1, 0.30), face(0.5, 0.29)], sharpness: 40)
        let spots = Culling.reasonSpots([keeper, blink, soft], keeper: 0)
        XCTAssertNil(spots[0], "the keeper gets no note")
        // The second face's box is x 0.5...0.6, y 0.5...0.65 from the bottom.
        let spot = spots[1]
        XCTAssertNotNil(spot)
        XCTAssertEqual(spot?.x ?? 0, 0.55, accuracy: 1e-9)
        XCTAssertEqual(spot?.y ?? 0, 1 - 0.575, accuracy: 1e-9, "measured down from the top")
        XCTAssertNil(spots[2], "softness is about the whole photo")
    }

    func testFacesMatchPeopleWhoMoveALittle() {
        let faces: [[CullFace]] = [[face(0.2, 0.3), face(0.6, 0.3)], [face(0.62, 0.3), face(0.23, 0.3)], [face(0.9, 0.3)]]
        XCTAssertEqual(Culling.people(in: faces), [[0, 1], [1, 0], [2]])
    }

    // MARK: Picking

    private func photo(faces: [CullFace] = [], sharpness: Double = 100, brightness: Double = 0.18,
                       highlights: Double = 0, aesthetics: Double? = nil) -> CullSignals {
        CullSignals(sharpness: sharpness, faceQuality: faces.compactMap(\.quality).max(), faces: faces,
                    subjectSharpness: sharpness, exposure: CullExposure(brightness: brightness, highlights: highlights),
                    aesthetics: aesthetics)
    }

    func testOneBlinkInAGroupIsNoLongerHiddenByTheBestFace() {
        // The old pick took the best face only, so the sharper shot with one blink won.
        let sharpWithBlink = photo(faces: [face(0.1, 0.30, quality: 0.9), face(0.5, 0.05, quality: 0.3)], sharpness: 400)
        let softerAllOpen = photo(faces: [face(0.1, 0.31, quality: 0.8), face(0.5, 0.29, quality: 0.75)], sharpness: 330)
        let group = [sharpWithBlink, softerAllOpen]
        XCTAssertEqual(Culling.keeper(group, by: .classic), 0, "Classic keeps today's behavior")
        XCTAssertEqual(Culling.keeper(group, by: .balanced), 1)
        XCTAssertEqual(Culling.keeper(group, by: .eyesOpen), 1)
        XCTAssertEqual(Culling.keeper(group, by: .sharpestSubject), 0)
    }

    func testBestExposurePrefersTheUnclippedShot() {
        let group = [photo(sharpness: 120, brightness: 0.45, highlights: 0.08),
                     photo(sharpness: 100, brightness: 0.18),
                     photo(sharpness: 90, brightness: 0.17)]
        XCTAssertEqual(Culling.keeper(group, by: .bestExposure), 1)
        XCTAssertEqual(Culling.keeper(group, by: .sharpestSubject), 0)
        XCTAssertEqual(Culling.keeper(group, by: .balanced), 1, "a big exposure miss costs more than a little sharpness")
    }

    func testAdvancedEyeSharpnessCountsOnlyWhenEveryPhotoHasIt() {
        var a = photo(faces: [face(0.3, 0.3)], sharpness: 100), b = photo(faces: [face(0.3, 0.3)], sharpness: 80)
        a.faces[0].eyeSharpness = 50
        a.advanced = true
        XCTAssertFalse(Culling.assess([a, b])[0].onEyes, "sizes differ until both are read")
        b.faces[0].eyeSharpness = 200
        b.advanced = true
        let assessed = Culling.assess([a, b])
        XCTAssertTrue(assessed[0].onEyes)
        XCTAssertEqual(assessed[0].sharpness, 0.25, accuracy: 0.001)
        XCTAssertEqual(Culling.keeper([a, b], by: .sharpestSubject), 1, "the eyes decide, not the whole face")
    }

    // MARK: Words

    func testReasonsSayOnlyWhatWasMeasured() {
        var keeper = CullAssessment(), photo = CullAssessment()
        keeper.faces = 5; keeper.judged = 5
        photo.faces = 5; photo.judged = 5; photo.closed = 2
        photo.sharpness = 0.58; photo.coherence = 0.5; keeper.coherence = 0.2
        photo.stops = -1.3
        XCTAssertEqual(Culling.reasons(photo, keeper: keeper), [
            "Eyes closed: 2 of 5 people (keeper: none)",
            "Subject softer: 58% of the keeper's sharpness, looks like motion blur",
            "1.3 stops darker than the keeper",
        ])
        var single = CullAssessment(), singleKeeper = CullAssessment()
        single.faces = 1; single.judged = 1; single.closed = 1; single.sharpness = 0.5
        singleKeeper.faces = 1; singleKeeper.judged = 1
        XCTAssertEqual(Culling.reasons(single, keeper: singleKeeper),
                       ["Eyes closed", "Subject softer: 50% of the keeper's sharpness, looks out of focus"])
        XCTAssertEqual(Culling.reasons(keeper, keeper: keeper), [], "nothing worse, nothing written")
    }

    func testReasonNoteIsAHeadingAndABulletPerReason() {
        let note = Culling.reasonNote(name: "DSC_0102.NEF", groupSize: 6, sameFrame: false, keeperChosenByYou: false,
                                      reasons: ["Eyes closed: 2 of 5 people (keeper: none)"], droppedSuggestion: true)
        XCTAssertEqual(note, """
            Not kept: group of 6 (Similar shots), keeper DSC_0102.NEF.
            - Eyes closed: 2 of 5 people (keeper: none)
            - You dropped it (Atelier suggested keeping it)
            """)
        let close = Culling.reasonNote(name: "A.NEF", groupSize: 2, sameFrame: true, keeperChosenByYou: true,
                                       reasons: [], droppedSuggestion: false)
        XCTAssertEqual(close, "Not kept: group of 2 (Same frame), keeper A.NEF (your pick).\n- Measured about as good as the keeper: a close call")
    }

    func testCaption() {
        var a = CullAssessment()
        a.sharpness = 0.82; a.faces = 6; a.judged = 6; a.closed = 1
        XCTAssertEqual(Culling.caption(a, inGroup: true), "Sharpness 82% of the group's best · Eyes: 5 of 6 open, 1 closed · Exposure OK")
        a.judged = 0; a.highlights = 0.04
        XCTAssertEqual(Culling.caption(a, inGroup: false),
                       "Eyes: not checked (faces too small or turned) · Highlights clipped: 4% of the frame")
    }

    // MARK: Measures

    func testMotionBlurRunsOneWay() {
        let side = 96
        // Random dots, then the same smeared sideways (motion) and blurred both ways (focus).
        var generator = SystemRandomNumberGenerator()
        let dots = (0..<(side * side)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        func blurred(dx: Int, dy: Int) -> GrayPlane {
            var out = [UInt8](repeating: 0, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    var sum = 0, count = 0
                    for oy in -dy...dy { for ox in -dx...dx {
                        let sx = min(max(x + ox, 0), side - 1), sy = min(max(y + oy, 0), side - 1)
                        sum += Int(dots[sy * side + sx]); count += 1
                    } }
                    out[y * side + x] = UInt8(sum / count)
                }
            }
            return GrayPlane(width: side, height: side, pixels: out)
        }
        let motion = blurred(dx: 4, dy: 0), focus = blurred(dx: 2, dy: 2)
        XCTAssertGreaterThan(motion.edgeCoherence(), focus.edgeCoherence() + 0.3)
        XCTAssertGreaterThan(GrayPlane(width: side, height: side, pixels: dots).laplacianVariance(), focus.laplacianVariance() * 4)
    }

    func testExposureInStopsAndClipping() {
        let half = [UInt8](repeating: 255, count: 50) + [UInt8](repeating: 0, count: 50)
        let exposure = GrayPlane(width: 10, height: 10, pixels: half).exposure()
        XCTAssertEqual(exposure.highlights, 0.5, accuracy: 0.001)
        XCTAssertEqual(exposure.shadows, 0.5, accuracy: 0.001)
        XCTAssertEqual(CullExposure(brightness: 0.09).stops(from: CullExposure(brightness: 0.18)), -1, accuracy: 0.001)
    }
}
