import XCTest
@testable import AtelierCore

final class SliderGeometryTests: XCTestCase {
    func testKnobStaysInsideTheSliderAtBothEnds() {
        let width = 160.0
        XCTAssertEqual(SliderGeometry.x(fraction: 0, width: width) - SliderGeometry.knobDiameter / 2, 0, accuracy: 1e-9)
        XCTAssertEqual(SliderGeometry.x(fraction: 1, width: width) + SliderGeometry.knobDiameter / 2, width, accuracy: 1e-9)
        XCTAssertEqual(SliderGeometry.x(fraction: 0.5, width: width), width / 2, accuracy: 1e-9)
    }

    func testFractionRoundTripsAndClamps() {
        let width = 200.0
        for f in stride(from: 0.0, through: 1.0, by: 0.125) {
            let x = SliderGeometry.x(fraction: f, width: width)
            XCTAssertEqual(SliderGeometry.fraction(x: x, width: width), f, accuracy: 1e-9)
        }
        XCTAssertEqual(SliderGeometry.fraction(x: -20, width: width), 0)
        XCTAssertEqual(SliderGeometry.fraction(x: 400, width: width), 1)
        XCTAssertEqual(SliderGeometry.fraction(x: 5, width: 4), 0, "A slider too narrow for its knob has no track")
    }

    func testPressOnKnobKeepsItsPlacePressOffKnobJumps() {
        let knobX = 80.0
        // Inside the 20 pt zone: no jump, the knob stays under the pointer.
        XCTAssertTrue(SliderGeometry.isOnKnob(knobX + 9.5, knobX: knobX))
        XCTAssertEqual(SliderGeometry.grabOffset(start: knobX + 9.5, knobX: knobX), -9.5, accuracy: 1e-9)
        XCTAssertEqual(SliderGeometry.grabOffset(start: knobX - 4, knobX: knobX), 4, accuracy: 1e-9)
        // Outside it: the knob jumps to the pointer.
        XCTAssertFalse(SliderGeometry.isOnKnob(knobX + 10.5, knobX: knobX))
        XCTAssertEqual(SliderGeometry.grabOffset(start: knobX + 30, knobX: knobX), 0)
    }

    func testGrabZoneIsWiderThanTheKnob() {
        XCTAssertGreaterThan(SliderGeometry.grabZone, SliderGeometry.knobDiameter)
        XCTAssertLessThanOrEqual(SliderGeometry.grabZone, SliderGeometry.height)
    }

    func testValuesRoundToStepAndStayInRange() {
        XCTAssertEqual(SliderGeometry.value(at: 0.5, in: -100...100, step: 1), 0)
        XCTAssertEqual(SliderGeometry.value(at: 0.503, in: -100...100, step: 1), 1)
        XCTAssertEqual(SliderGeometry.value(at: 2, in: -100...100, step: 1), 100)
        XCTAssertEqual(SliderGeometry.value(at: 0.25, in: 0...1, step: 0), 0.25, accuracy: 1e-12)
        XCTAssertEqual(SliderGeometry.fraction(of: 50, in: 0...100), 0.5, accuracy: 1e-12)
        XCTAssertEqual(SliderGeometry.fraction(of: 500, in: 0...100), 1)
    }

    func testLogarithmicTrackRoundTrips() {
        let range = 2000.0...50000.0
        for kelvin in [2000.0, 3200, 5500, 6500, 12000, 50000] {
            let f = SliderGeometry.fraction(of: kelvin, in: range, logarithmic: true)
            XCTAssertEqual(SliderGeometry.value(at: f, in: range, step: 0, logarithmic: true), kelvin, accuracy: 1e-6)
        }
        // Halfway along is the geometric mean, not the arithmetic one.
        XCTAssertEqual(SliderGeometry.value(at: 0.5, in: range, step: 0, logarithmic: true), 10000, accuracy: 1e-6)
    }
}
