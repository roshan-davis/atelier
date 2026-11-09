import XCTest
@testable import AtelierCore

final class KeyboardTests: XCTestCase {
    func testOldSingleKeySettingsStillRead() {
        XCTAssertEqual(KeyCombo(stored: "p"), KeyCombo("p"))
        XCTAssertEqual(KeyCombo(stored: "\\"), KeyCombo("\\"))
        XCTAssertNil(KeyCombo(stored: ""))
        XCTAssertEqual(KeyCombo(stored: "P")?.key, "p")
    }

    func testCombosRoundTrip() {
        let combos = [KeyCombo(KeyCombo.tab, modifiers: .control),
                      KeyCombo(KeyCombo.tab, modifiers: [.control, .shift]),
                      KeyCombo("w", modifiers: .shift),
                      KeyCombo("F6"),
                      KeyCombo("m", modifiers: [.control, .option, .shift])]
        for combo in combos {
            XCTAssertEqual(KeyCombo(stored: combo.stored), combo, combo.stored)
        }
        XCTAssertEqual(KeyCombo("m", modifiers: [.shift, .control]).stored, "⌃⇧m")
        // A lone symbol is a key, not a modifier.
        XCTAssertEqual(KeyCombo(stored: "⇧")?.key, "⇧")
    }

    func testDisplay() {
        XCTAssertEqual(KeyCombo(KeyCombo.tab, modifiers: .control).display, "⌃Tab")
        XCTAssertEqual(KeyCombo("w", modifiers: .shift).display, "⇧W")
        XCTAssertEqual(KeyCombo("F6").display, "F6")
        XCTAssertEqual(KeyCombo(" ").display, "Space")
    }

    func testLookupPrefersExactThenFallsBackFromShift() {
        let bindings: [(String, KeyCombo?)] = [("whiteBalance", KeyCombo("w")),
                                               ("masking", KeyCombo("w", modifiers: .shift)),
                                               ("pick", KeyCombo("p")),
                                               ("removed", nil)]
        XCTAssertEqual(KeyCombo.command(for: KeyCombo("w", modifiers: .shift), in: bindings), "masking")
        XCTAssertEqual(KeyCombo.command(for: KeyCombo("w"), in: bindings), "whiteBalance")
        XCTAssertEqual(KeyCombo.command(for: KeyCombo("p", modifiers: .shift), in: bindings), "pick")
        XCTAssertNil(KeyCombo.command(for: KeyCombo("p", modifiers: .control), in: bindings))
    }

    func testSliderNudgeSteps() {
        // Contrast: 1 a press, 5 with Shift.
        XCTAssertEqual(SliderNudge.value(from: 0, range: -100...100, step: 1, direction: 1, large: false), 1)
        XCTAssertEqual(SliderNudge.value(from: 0, range: -100...100, step: 1, direction: -1, large: true), -5)
        // Exposure: 0.05 a press.
        XCTAssertEqual(SliderNudge.value(from: 0, range: -5...5, step: 0.01, direction: 1, large: false), 0.05, accuracy: 1e-9)
        // Never less than one step, even when 1/200 of the track rounds to nothing.
        XCTAssertEqual(SliderNudge.value(from: 1, range: 0.5...3, step: 0.1, direction: 1, large: false), 1.1, accuracy: 1e-9)
        // Stops at the ends.
        XCTAssertEqual(SliderNudge.value(from: 100, range: -100...100, step: 1, direction: 1, large: true), 100)
        // Temperature moves along its logarithmic track.
        let warmer = SliderNudge.value(from: 5500, range: 2000...50000, step: 1, logarithmic: true, direction: 1, large: false)
        XCTAssertGreaterThan(warmer, 5500)
        XCTAssertLessThan(warmer, 5700)
    }
}

final class LatestJobTests: XCTestCase {
    func testOnlyTheNewestValueWaits() {
        let job = LatestJob<Int>()
        XCTAssertTrue(job.submit(1))   // starts a drain
        XCTAssertFalse(job.submit(2))  // replaces 1 while the drain is pending
        XCTAssertFalse(job.submit(3))
        XCTAssertEqual(job.take(), 3)
        XCTAssertNil(job.take())       // drain ends
        XCTAssertTrue(job.submit(4))   // the next value starts a new drain
        XCTAssertEqual(job.take(), 4)
        XCTAssertNil(job.take())
    }
}

final class LockedValueTests: XCTestCase {
    func testReadsTheLastWrite() {
        let open = LockedValue<Int64?>(nil)
        XCTAssertNil(open.value)
        open.value = 7
        XCTAssertEqual(open.value, 7)
    }
}

final class LatestJobObsoleteTests: XCTestCase {
    func testAnObsoleteValueNeverReplacesTheWaitingOne() {
        let job = LatestJob<Int>()
        XCTAssertTrue(job.submit(1))                       // photo 1 starts a drain
        XCTAssertFalse(job.submit(2))                      // photo 2's request waits
        XCTAssertFalse(job.submit(1, if: { new, _ in new == 2 }))  // a late request for photo 1 is dropped
        XCTAssertEqual(job.take(), 2)
        XCTAssertNil(job.take())
    }

    func testAWaitingValueThatOutranksTheNewOneStays() {
        let job = LatestJob<Int>()
        let higherWins: (Int, Int?) -> Bool = { new, pending in new >= (pending ?? .min) }
        XCTAssertTrue(job.submit(0))
        XCTAssertFalse(job.submit(5, if: higherWins))      // the render's request waits
        XCTAssertFalse(job.submit(4, if: higherWins))      // a lower-ranked preview arriving late is dropped
        XCTAssertEqual(job.take(), 5)
        XCTAssertNil(job.take())
    }
}
