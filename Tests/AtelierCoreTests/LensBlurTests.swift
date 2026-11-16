import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import AtelierCore

/// Lens Blur (AT-072): its settings, the focal range, and the blur on a stand-in depth.
final class LensBlurTests: XCTestCase {
    private typealias Parameter = DevelopSettings.Parameter

    func testSlidersBelongToTheLensBlurPanelAndStartOff() throws {
        XCTAssertEqual(DevelopSettings.Panel.lensBlur.parameters,
                       [.lensBlurApply, .lensBlurAmount, .lensBlurBokeh, .lensBlurCatEye, .lensBlurBoost,
                        .lensBlurFocusNear, .lensBlurFocusFar])
        XCTAssertEqual(Parameter.lensDistortion.panel, .lensCorrections, "Lens Corrections keeps its own sliders")
        XCTAssertEqual(DevelopSettings.Panel.lensBlur.title, "Lens Blur")
        XCTAssertFalse(LensBlur.isOn(DevelopSettings()), "off until Apply")
        let old = try DevelopSettings.decoded(from: #"{"exposure":0.5}"#)
        XCTAssertFalse(LensBlur.isOn(old), "old edits look the same")
        var settings = DevelopSettings()
        settings[.lensBlurApply] = 1
        XCTAssertTrue(LensBlur.isOn(settings))
        settings[.lensBlurBokeh] = Double(LensBlur.Bokeh.ring.rawValue)
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()), settings)
        XCTAssertEqual(LensBlur.bokeh(settings), .ring)
        settings.disabledPanels = [.lensBlur]
        XCTAssertFalse(LensBlur.isOn(settings.applyingPanelSwitches()), "the panel switch turns it off")
        XCTAssertFalse(DevelopPreset.Part.defaults.contains(.lensBlur), "a focal range belongs to its photo")
    }

    func testBlurGrowsAwayFromTheFocalRangeOnBothSides() {
        XCTAssertEqual(LensBlur.blur(atDepth: 0.3, near: 0.2, far: 0.4), 0)
        XCTAssertEqual(LensBlur.blur(atDepth: 0.65, near: 0.2, far: 0.4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LensBlur.blur(atDepth: 1, near: 0.2, far: 0.4), 1, "the most behind")
        XCTAssertEqual(LensBlur.blur(atDepth: 0, near: 0.2, far: 0.4), -0.4, accuracy: 1e-9, "in front, negative")
    }

    func testFocalRangeFromPickedDepths() throws {
        let subject = (0..<100).map { Float(0.30 + 0.001 * Double($0)) } + [0.0, 1.0]
        let range = try XCTUnwrap(LensBlur.focalRange(for: subject))
        XCTAssertEqual(range.near, 30, accuracy: 1)
        XCTAssertEqual(range.far, 39, accuracy: 1)
        let flat = try XCTUnwrap(LensBlur.focalRange(for: [Float](repeating: 0.5, count: 9)))
        XCTAssertEqual(flat.near, 48)
        XCTAssertEqual(flat.far, 52, "a flat pick still keeps a little range")
        XCTAssertNil(LensBlur.focalRange(for: []))
    }

    /// A fine checker, near (depth 0) on the left half and far (1) on the right, focused near:
    /// the left stays as sharp as it was, right up to the edge, and the right turns smooth.
    func testFarHalfBlursAndNearHalfStaysSharp() throws {
        XCTAssertTrue(LensBlur.kernelAvailable)
        let width = 256, height = 64
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let level: Float = (x / 2 + y / 2) % 2 == 0 ? 0.8 : 0.05
                for c in 0..<3 { pixels[(y * width + x) * 4 + c] = level }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let photo = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                            format: .RGBAf, colorSpace: DevelopRenderer.workingSpace)
        let depth = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
            .composited(over: CIImage(color: .white).cropped(to: photo.extent))
        var settings = DevelopSettings()
        settings[.lensBlurApply] = 1
        settings[.lensBlurAmount] = 100
        settings[.lensBlurBoost] = 0
        settings[.lensBlurFocusNear] = 0
        settings[.lensBlurFocusFar] = 10
        let before = try render(photo, width: width, height: height)
        let after = try render(LensBlur.apply(photo, depth: depth, settings: settings), width: width, height: height)
        func spread(_ values: [Float], columns: Range<Int>) -> Float {
            var all: [Float] = []
            for y in 8..<(height - 8) { for x in columns { all.append(values[(y * width + x) * 4]) } }
            let mean = all.reduce(0, +) / Float(all.count)
            return all.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(all.count)
        }
        XCTAssertEqual(spread(after, columns: 4..<124), spread(before, columns: 4..<124), accuracy: 1e-3, "near stays sharp")
        XCTAssertLessThan(spread(after, columns: 136..<252), 0.1 * spread(before, columns: 136..<252), "far blurs")
        let edge = (height / 2 * width + width / 2 - 1) * 4
        XCTAssertEqual(after[edge], before[edge], accuracy: 0.02, "the far blur doesn't spill onto the sharp edge")
    }

    /// Focus and Blur areas are Lens Blur's own masks: kept apart from Masking's, carried by
    /// the Lens Blur preset part, and drawn as red (focus) and green (blur) at their strength.
    func testFocusAndBlurAreasBelongToLensBlur() throws {
        var focus = DevelopSettings.Mask(name: "Focus",
                                         components: [.init(.radial(.init(center: .init(x: 0.75, y: 0.5),
                                                                           radiusX: 0.2, radiusY: 0.4)))])
        focus.lensBlurRole = .focus
        XCTAssertFalse(focus.hasAdjustments, "an area changes nothing but the blur")
        XCTAssertEqual(focus.lensBlurStrength, 1)
        var settings = DevelopSettings()
        settings.lensBlurAreas = [focus]
        XCTAssertTrue(settings.masks.isEmpty, "areas never show in Masking")
        XCTAssertFalse(settings.isNeutral)
        XCTAssertEqual(try DevelopSettings.decoded(from: settings.encoded()), settings)
        let old = try DevelopSettings.decoded(from: #"{"masks":[{"name":"Mask 1","values":{"exposure":0.5}}]}"#)
        XCTAssertNil(old.masks.first?.lensBlurRole, "old masks stay ordinary masks")
        XCTAssertTrue(old.lensBlurAreas.isEmpty)

        let preset = DevelopPreset(name: "Blur", parts: [.lensBlur], settings: settings)
        XCTAssertEqual(preset.applied(to: DevelopSettings()).lensBlurAreas, [focus], "the Lens Blur part carries them")
        let masksOnly = DevelopPreset(name: "Masks", parts: [.masks], settings: settings)
        XCTAssertTrue(masksOnly.applied(to: DevelopSettings()).lensBlurAreas.isEmpty)

        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        XCTAssertNil(LensBlur.areas(DevelopSettings(), on: base, provider: nil), "no areas, nothing to pay")
        settings.lensBlurAreas[0].amount = 50
        let areas = try XCTUnwrap(LensBlur.areas(settings, on: base, provider: nil))
        let pixels = try render(areas, width: 64, height: 32)
        let inside = (16 * 64 + 48) * 4, outside = (16 * 64 + 4) * 4
        XCTAssertEqual(pixels[inside], 0.5, accuracy: 0.05, "focus strength (Amount) in red")
        XCTAssertEqual(pixels[inside + 1], 0, accuracy: 0.01)
        XCTAssertEqual(pixels[outside], 0, accuracy: 0.01)
        settings.lensBlurAreas[0].lensBlurRole = .blur
        let blurred = try render(try XCTUnwrap(LensBlur.areas(settings, on: base, provider: nil)), width: 64, height: 32)
        XCTAssertEqual(blurred[inside + 1], 0.5, accuracy: 0.05, "blur strength in green")
        settings.lensBlurAreas[0].isHidden = true
        XCTAssertNil(LensBlur.areas(settings, on: base, provider: nil), "a hidden area does nothing")
    }

    /// The far half of the checker, under a Focus area, stays sharp; the near half, under a Blur
    /// area, blurs although it is in the focal range.
    func testAreasOverrideTheDepth() throws {
        let width = 256, height = 64
        let photo = checker(width: width, height: height)
        let depth = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
            .composited(over: CIImage(color: .white).cropped(to: photo.extent))
        let areas = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
            .composited(over: CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: photo.extent))
        var settings = DevelopSettings()
        settings[.lensBlurApply] = 1
        settings[.lensBlurAmount] = 100
        settings[.lensBlurBoost] = 0
        settings[.lensBlurFocusNear] = 0
        settings[.lensBlurFocusFar] = 10
        let before = try render(photo, width: width, height: height)
        let after = try render(LensBlur.apply(photo, depth: depth, settings: settings, areas: areas),
                               width: width, height: height)
        XCTAssertEqual(spread(after, width: width, height: height, columns: 136..<252),
                       spread(before, width: width, height: height, columns: 136..<252), accuracy: 1e-3,
                       "the Focus area stays sharp although it is far")
        XCTAssertLessThan(spread(after, width: width, height: height, columns: 4..<120),
                          0.1 * spread(before, width: width, height: height, columns: 4..<120),
                          "the Blur area blurs although it is in focus")
    }

    private func checker(width: Int, height: Int) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let level: Float = (x / 2 + y / 2) % 2 == 0 ? 0.8 : 0.05
                for c in 0..<3 { pixels[(y * width + x) * 4 + c] = level }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: DevelopRenderer.workingSpace)
    }

    private func spread(_ values: [Float], width: Int, height: Int, columns: Range<Int>) -> Float {
        var all: [Float] = []
        for y in 8..<(height - 8) { for x in columns { all.append(values[(y * width + x) * 4]) } }
        let mean = all.reduce(0, +) / Float(all.count)
        return all.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(all.count)
    }

    func testOffLeavesTheImageAlone() {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertTrue(LensBlur.apply(image, depth: image, settings: DevelopSettings()) === image)
    }

    private func render(_ image: CIImage, width: Int, height: Int) throws -> [Float] {
        var out = [Float](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { buffer in
            DevelopRenderer.shared.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                                                  bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                                  format: .RGBAf, colorSpace: DevelopRenderer.workingSpace)
        }
        return out
    }
}
