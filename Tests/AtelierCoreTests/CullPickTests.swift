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
        let corners: [(Double, Double)] = [(-15, 0), (-8, 4.5), (0, 4.5), (8, 4.5), (15, 0), (8, -4.5), (0, -4.5), (-8, -4.5)]
        let cosine = cos(angle), sine = sin(angle)
        var outline: [CGPoint] = []
        for (x, y) in corners {
            let px: Double = 100 + x * cosine - y * sine
            let py: Double = 50 + x * sine + y * cosine
            outline.append(CGPoint(x: px, y: py))
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

    /// The subject Show Subject draws: the faces big enough to read, else the whole frame
    /// (Vision's salient object needs a real photo).
    func testSubjectIsTheFacesElseTheWholeFrame() {
        let faces = [face(0.1, 0.3), face(0.5, 0.3), CullFace(box: CGRect(x: 0.8, y: 0.1, width: 0.01, height: 0.01))]
        let subject = Culling.subject(faces: faces, people: [], saliency: nil, planeWidth: 1024)
        XCTAssertEqual(subject.kind, .faces)
        XCTAssertEqual(subject.box.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(subject.box.maxX, 0.6, accuracy: 1e-9, "the 10 px face is left out")
        XCTAssertEqual(Culling.subject(faces: [], people: [], saliency: nil, planeWidth: 1024), CullSubject(kind: .wholeFrame))
    }

    /// No face found (sunglasses, turned away): the people Vision found are the subject.
    func testSubjectIsThePeopleWhenNoFaceIsFound() {
        let people = [CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.6), CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.95)]
        let subject = Culling.subject(faces: [], people: people, saliency: nil, planeWidth: 1024)
        XCTAssertEqual(subject.kind, .people)
        XCTAssertEqual(subject.box.minX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(subject.box.maxX, 0.7, accuracy: 1e-9)
        XCTAssertEqual(subject.box.maxY, 1, accuracy: 1e-9, "kept inside the frame")
    }

    /// The grid gives the same variance as measuring the pixels of a region directly, and rows
    /// are counted from the top (a Vision box's maxY is the top).
    func testSharpnessGridMeasuresARegion() {
        let side = 64
        var pixels = [UInt8](repeating: 128, count: side * side)
        // Noise in the top half only.
        var seed: UInt32 = 7
        for y in 0..<(side / 2) {
            for x in 0..<side {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[y * side + x] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        let plane = GrayPlane(width: side, height: side, pixels: pixels)
        let grid = plane.laplacianGrid(cells: 16)
        let top = grid.variance(in: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let bottom = grid.variance(in: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        XCTAssertGreaterThan(top, bottom * 100)
        XCTAssertEqual(grid.variance(in: CGRect(x: 0, y: 0, width: 1, height: 1)), plane.laplacianVariance(), accuracy: plane.laplacianVariance() * 1e-9)
    }

    /// Without faces in every shot, a group is measured on one region (the union of the
    /// subjects), so near-identical shots compare the same pixels.
    func testGroupWithoutFacesSharesOneRegion() {
        var a = photo(), b = photo()
        a.subject = CullSubject(kind: .object, box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        b.subject = CullSubject(kind: .people, box: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5))
        XCTAssertNil(Culling.sharedSubject([a, b]), "needs the grids")
        a.sharpnessGrid = CullSharpnessGrid(cells: 4)
        b.sharpnessGrid = CullSharpnessGrid(cells: 4)
        let shared = Culling.sharedSubject([a, b])
        XCTAssertEqual(shared?.kind, .people)
        XCTAssertEqual(shared?.box.minX ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(shared?.box.maxY ?? 0, 0.7, accuracy: 1e-9)
        var c = photo(faces: [face(0.1, 0.3)]), d = photo(faces: [face(0.1, 0.3)])
        c.subject = CullSubject(kind: .faces); d.subject = CullSubject(kind: .faces)
        c.sharpnessGrid = CullSharpnessGrid(cells: 4); d.sharpnessGrid = CullSharpnessGrid(cells: 4)
        XCTAssertNil(Culling.sharedSubject([c, d]), "faces are read face by face")
    }

    /// MediaPipe's face detector: anchors in the model's order, a box from one anchor's
    /// offsets, and overlapping boxes reduced to the best.
    func testFaceDetectorDecodesBoxes() {
        XCTAssertEqual(FaceDetector.anchors.count, 896)
        XCTAssertEqual(FaceDetector.anchors[0].x, 0.5 / 16, accuracy: 1e-9)
        XCTAssertEqual(FaceDetector.anchors[512].x, 0.5 / 8, accuracy: 1e-9, "the 8 x 8 grid starts after 16 x 16 x 2")
        var regressors = [Float](repeating: 0, count: 896 * 16)
        var logits = [Float](repeating: -10, count: 896)
        // Anchor 0 of cell (8, 8) on the 16 grid: center (8.5/16, 8.5/16).
        let i = (8 * 16 + 8) * 2
        regressors[i * 16] = 6.4; regressors[i * 16 + 1] = -6.4      // +0.05, -0.05
        regressors[i * 16 + 2] = 25.6; regressors[i * 16 + 3] = 32    // 0.2 x 0.25
        logits[i] = 3
        // A weaker box on the same face, and one far away under the threshold.
        regressors[(i + 1) * 16 + 2] = 25.6; regressors[(i + 1) * 16 + 3] = 32
        logits[i + 1] = 1
        logits[0] = -1
        let found = FaceDetector.decode(regressors: regressors, logits: logits)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].box.midX, 8.5 / 16 + 0.05, accuracy: 1e-6)
        XCTAssertEqual(found[0].box.midY, 8.5 / 16 - 0.05, accuracy: 1e-6)
        XCTAssertEqual(found[0].box.width, 0.2, accuracy: 1e-6)
        XCTAssertEqual(found[0].score, 1 / (1 + exp(-3)), accuracy: 1e-6)
    }

    /// MediaPipe looks for a head in the top half of each person.
    func testFaceDetectorLooksAtThePersonsTopHalf() {
        let head = FaceDetector.headRegion(of: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.8))
        XCTAssertEqual(head.minY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(head.maxY, 0.9, accuracy: 1e-9)
        XCTAssertEqual(head.minX, 0.38, accuracy: 1e-9)
        XCTAssertTrue(Culling.sameFace(CGRect(x: 0.4, y: 0.6, width: 0.1, height: 0.1), CGRect(x: 0.42, y: 0.62, width: 0.05, height: 0.05)))
        XCTAssertFalse(Culling.sameFace(CGRect(x: 0.1, y: 0.6, width: 0.1, height: 0.1), CGRect(x: 0.5, y: 0.6, width: 0.1, height: 0.1)))
    }

    /// Find Faces switches to another finder's faces and subject without reading again, and
    /// those faces need the Advanced checks again.
    func testFindFacesSwitchesFaceSets() {
        var signals = photo(faces: [face(0.1, 0.3)])
        signals.advanced = true
        let mediaPipe = [face(0.1, 0.3), face(0.5, 0.3)]
        signals.faceSets[.vision] = CullFaceSet(faces: signals.faces, subject: CullSubject(kind: .faces), subjectSharpness: 100, coherence: 0)
        signals.faceSets[.mediaPipe] = CullFaceSet(faces: mediaPipe, subject: CullSubject(kind: .faces), subjectSharpness: 80, coherence: 0.2)
        let switched = signals.using(.mediaPipe)
        XCTAssertEqual(switched.finder, .mediaPipe)
        XCTAssertEqual(switched.faces.count, 2)
        XCTAssertEqual(switched.subjectSharpness, 80)
        XCTAssertFalse(switched.advanced)
        XCTAssertEqual(signals.using(.vision).advanced, true, "the same finder changes nothing")
        XCTAssertEqual(signals.using(.both).faces.count, 1, "a finder that wasn't read changes nothing")
    }

    // MARK: Background faces

    /// A face `width` wide at `x` whose sharpness (variance of the Laplacian) is `sharpness`.
    private func face(_ x: Double, width: Double, sharpness: Double, openness: Double = 0.3) -> CullFace {
        CullFace(box: CGRect(x: x, y: 0.5, width: width, height: width * 1.2), quality: 0.6, openness: openness,
                 sharpness: sharpness)
    }

    /// Rosh's Z62_9227 (Nov 14, 2026): him in focus, and a blurred passer-by behind him that
    /// MediaPipe took for a face, read as "Eyes half closed: 1 of 2 people". Sharpness as
    /// measured on the Cull preview (1338 and 2).
    func testBlurredBackgroundFaceIsLeftOut() {
        let rosh = face(0.24, width: 0.13, sharpness: 1338)
        var passerBy = face(0.7, width: 0.17, sharpness: 2, openness: 0.12)
        passerBy.expression = FaceExpression(blinkLeft: 0.75, blinkRight: 0.75, smileLeft: 0, smileRight: 0)
        let shot = photo(faces: [rosh, passerBy])
        XCTAssertEqual(CullBackground.inFrame(shot.faces), [false, true])
        XCTAssertEqual(Culling.eyes(in: [shot.faces]), [[.open, .background]])
        let assessed = Culling.assess([shot])[0]
        XCTAssertEqual(assessed.faces, 1)
        XCTAssertEqual(assessed.background, 1)
        XCTAssertEqual(assessed.judged, 1)
        XCTAssertEqual(assessed.closed + assessed.halfClosed, 0, "the passer-by's eyes don't count")
        XCTAssertEqual(assessed.subject.kind, .faces)
        XCTAssertEqual(assessed.subject.box.minX, 0.24, accuracy: 1e-9)
        XCTAssertEqual(assessed.subject.box.maxX, 0.37, accuracy: 1e-9, "the subject is Rosh's face only")
        XCTAssertNil(Culling.reasonSpots([photo(faces: [rosh]), shot], keeper: 0)[1], "no note on the passer-by")
    }

    /// The thresholds against the faces measured on the test photos: faces in focus read 0.41
    /// to 1 of the sharpest; background faces 0.002 to 0.24 (the 0.24 one is small).
    func testBackgroundThresholds() {
        // group-5-outdoor: smooth skin in focus reads 0.41 of a bearded face.
        XCTAssertEqual(CullBackground.inFrame([face(0.1, width: 0.105, sharpness: 100), face(0.3, width: 0.107, sharpness: 41),
                                               face(0.5, width: 0.126, sharpness: 63)]), [false, false, false])
        // profile.jpg: the café behind the couple, 0.065 to 0.24 and about a third their width.
        XCTAssertEqual(CullBackground.inFrame([face(0.2, width: 0.107, sharpness: 548), face(0.6, width: 0.103, sharpness: 376),
                                               face(0.45, width: 0.034, sharpness: 42), face(0.52, width: 0.029, sharpness: 132)]),
                       [false, false, true, true])
        // Just as soft but as big as the sharp face: kept (the small-face rule needs half the width).
        XCTAssertEqual(CullBackground.inFrame([face(0.2, width: 0.1, sharpness: 100), face(0.6, width: 0.09, sharpness: 30)]),
                       [false, false])
        // Without sharpness (no copy to measure on) nothing is background.
        XCTAssertEqual(CullBackground.inFrame([CullFace(box: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.1)),
                                               CullFace(box: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))]), [false, false])
    }

    /// Focus slipping to the person behind in one shot doesn't swap who the subject is: that
    /// shot is the soft one.
    func testMissedFocusShotKeepsItsSubject() {
        let sharp = photo(faces: [face(0.24, width: 0.13, sharpness: 1300), face(0.7, width: 0.12, sharpness: 20)])
        let sharp2 = photo(faces: [face(0.25, width: 0.13, sharpness: 1250), face(0.71, width: 0.12, sharpness: 25)])
        let missed = photo(faces: [face(0.24, width: 0.13, sharpness: 90), face(0.7, width: 0.12, sharpness: 900)])
        let background = Culling.background(in: [sharp.faces, sharp2.faces, missed.faces])
        XCTAssertEqual(background, [[false, true], [false, true], [false, true]])
        let assessed = Culling.assess([sharp, sharp2, missed])
        XCTAssertEqual(assessed[2].sharpness, 90.0 / 1300, accuracy: 1e-6, "measured on Rosh, now soft")
        XCTAssertEqual(Culling.keeper([sharp, sharp2, missed], by: .sharpestSubject), 0)
        XCTAssertNotEqual(Culling.keeper([sharp, sharp2, missed], by: .balanced), 2)
        // Two shots, one each way: nothing to go by, so neither face is left out.
        XCTAssertEqual(Culling.background(in: [sharp.faces, missed.faces]), [[false, false], [false, false]])
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
