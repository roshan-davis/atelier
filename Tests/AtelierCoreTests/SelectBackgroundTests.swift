import CoreImage
import Foundation
import XCTest
@testable import AtelierCore

/// Select Background (AT-068): the subject Vision finds, turned inside out.
final class SelectBackgroundTests: XCTestCase {
    private typealias Component = DevelopSettings.MaskComponent
    private typealias Selection = DevelopSettings.Selection

    func testBackgroundSavesAsItsOwnKind() throws {
        var settings = DevelopSettings()
        settings.masks = [DevelopSettings.Mask(name: "Mask 1", components: [
            Component(.subject(Selection(feather: 30, grow: 20, background: true))),
        ])]
        let decoded = try DevelopSettings.decoded(from: settings.encoded())
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.masks.first?.components.first?.kind, .background)
        XCTAssertEqual(decoded.masks.first?.components.first?.kind.title, "Select Background")
        XCTAssertNil(decoded.masks.first?.components.first?.pin)

        // A bare part of that kind is a background; old subjects stay subjects.
        let bare = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","components":[{"kind":"background"}]}]}"#)
        XCTAssertEqual(bare.masks.first?.components.first?.kind, .background)
        let old = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","components":[{"kind":"subject"}]}]}"#)
        XCTAssertEqual(old.masks.first?.components.first?.kind, .subject)
    }

    func testBackgroundIsTheSubjectInvertedAndGrowReachesOntoTheSubject() throws {
        let extent = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        // The "subject": a white square from 250 to 750.
        let subjectMask = CIImage(color: .white).cropped(to: CGRect(x: 250, y: 250, width: 500, height: 500))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        func mask(_ selection: Selection) throws -> CIImage {
            try XCTUnwrap(DevelopRenderer.sourceMask(Component(.subject(selection)), extent: extent,
                                                     subject: { _ in subjectMask }, brushCache: nil))
        }
        let subject = try mask(Selection(feather: 0))
        let background = try mask(Selection(feather: 0, background: true))
        XCTAssertEqual(try value(subject, x: 500, y: 500), 1, accuracy: 0.01)
        XCTAssertEqual(try value(background, x: 500, y: 500), 0, accuracy: 0.01)
        XCTAssertEqual(try value(background, x: 50, y: 50), 1, accuracy: 0.01)

        // Grow +100 (10 px on a 1000 px photo) takes the background 10 px onto the subject.
        let grown = try mask(Selection(feather: 0, grow: 100, background: true))
        XCTAssertEqual(try value(grown, x: 255, y: 500), 1, accuracy: 0.01)
        XCTAssertEqual(try value(grown, x: 500, y: 500), 0, accuracy: 0.01)
        XCTAssertEqual(try value(background, x: 255, y: 500), 0, accuracy: 0.01)

        // No subject found: no background either (the panel says so).
        XCTAssertNil(DevelopRenderer.sourceMask(Component(.subject(Selection(background: true))), extent: extent,
                                                subject: { _ in nil }, brushCache: nil))
    }

    /// The mask's value at a pixel (Core Image coordinates).
    private func value(_ image: CIImage, x: Int, y: Int) throws -> Double {
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        pixel.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        return Double(pixel[0])
    }
}
