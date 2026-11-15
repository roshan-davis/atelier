import CoreImage
import Foundation
import XCTest
@testable import AtelierCore

/// A mask's own Color Grading (Lightroom Classic 16; AT-068).
final class MaskColorGradingTests: XCTestCase {
    private typealias Mask = DevelopSettings.Mask

    func testGradeSavesOnlyChangesAndOldMasksDecodeWithout() throws {
        var mask = Mask(name: "Mask 1")
        XCTAssertFalse(mask.hasGrade)
        XCTAssertEqual(mask[grade: .gradeBlending], DevelopSettings.Parameter.gradeBlending.defaultValue)
        mask[grade: .gradeShadowsHue] = 220
        mask[grade: .gradeShadowsSat] = 140
        mask[grade: .exposure] = 2
        XCTAssertTrue(mask.hasGrade)
        XCTAssertTrue(mask.hasAdjustments)
        XCTAssertEqual(mask[grade: .gradeShadowsSat], DevelopSettings.Parameter.gradeShadowsSat.range.upperBound, "clamped")
        XCTAssertEqual(mask[grade: .exposure], DevelopSettings.Parameter.exposure.defaultValue, "only Color Grading parameters")

        var settings = DevelopSettings()
        settings.masks = [mask]
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.masks.first?[grade: .gradeShadowsHue], 220)

        let old = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","values":{"exposure":0.5}}]}"#)
        XCTAssertEqual(old.masks.first?.hasGrade, false)

        mask[grade: .gradeShadowsHue] = DevelopSettings.Parameter.gradeShadowsHue.defaultValue
        mask[grade: .gradeShadowsSat] = 0
        XCTAssertFalse(mask.hasGrade, "back at the defaults, nothing is kept")
        mask[grade: .gradeMidtonesSat] = 30
        mask.resetAdjustments()
        XCTAssertFalse(mask.hasGrade, "Reset Sliders clears the grade too")
    }

    func testAmountScalesStrengthNotDirection() {
        var mask = Mask(name: "Mask 1")
        mask[grade: .gradeHighlightsHue] = 40
        mask[grade: .gradeHighlightsSat] = 60
        mask[grade: .gradeHighlightsLum] = -20
        mask[grade: .gradeBalance] = 30
        mask.amount = 50
        XCTAssertEqual(mask.effective(grade: .gradeHighlightsHue), 40)
        XCTAssertEqual(mask.effective(grade: .gradeHighlightsSat), 30)
        XCTAssertEqual(mask.effective(grade: .gradeHighlightsLum), -10)
        XCTAssertEqual(mask.effective(grade: .gradeBalance), 30)
    }

    func testMaskGradeTintsTheMaskedArea() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let gray = try XCTUnwrap(CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1, colorSpace: space))
        let image = CIImage(color: gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        var mask = Mask(name: "Mask 1")
        mask[grade: .gradeGlobalHue] = 230
        mask[grade: .gradeGlobalSat] = 70
        let output = DevelopRenderer.applyLocal(mask, to: image, scale: 1)
        let context = CIContext(options: [.workingColorSpace: space, .outputPremultiplied: false])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 8, y: 8, width: 1, height: 1),
                       format: .RGBAf, colorSpace: space)
        XCTAssertGreaterThan(pixel[2], pixel[0] + 0.01, "a blue Global wheel turns the gray blue: \(pixel)")
    }
}
