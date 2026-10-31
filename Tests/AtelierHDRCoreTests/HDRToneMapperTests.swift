import XCTest
@testable import AtelierHDRCore

final class HDRToneMapperTests: XCTestCase {
    func testMiddleGrayAndBlackAreStableAcrossCompression() throws {
        for value: Float in [0, 0.18] {
            let image = try HDRImage(width: 4, height: 4, rgb: Array(repeating: value, count: 48))
            for compression: Float in [0, 0.5, 1] {
                var settings = HDRSettings(); settings.compression = compression
                let result = try HDRToneMapper.render(image, settings: settings)
                XCTAssertEqual(result.rgb[0], value, accuracy: 0.000001)
            }
        }
    }

    func testDirectShoulderIsMonotonicAndPreservesColorRatios() throws {
        let rgb = (0..<512).flatMap { i -> [Float] in
            let l = powf(2, Float(i)/511*14-10)
            return [l, l*0.6, l*0.3]
        }
        let image = try HDRImage(width: 512, height: 1, rgb: rgb)
        let result = try HDRToneMapper.render(image, settings: HDRSettings())
        for i in 1..<512 {
            XCTAssertGreaterThan(result.rgb[i*3], result.rgb[(i-1)*3])
            XCTAssertEqual(result.rgb[i*3+1]/result.rgb[i*3], 0.6, accuracy: 0.00001)
            XCTAssertEqual(result.rgb[i*3+2]/result.rgb[i*3], 0.3, accuracy: 0.00001)
        }
        XCTAssertLessThan(result.rgb.last!, image.rgb.last!)
    }

    func testExposureIdentityAndInputPreservation() throws {
        let image = try HDRImage(width: 1, height: 1, rgb: [0.1,0.2,0.4])
        var settings = HDRSettings(); settings.compression = 0; settings.exposure = 1; settings.microcontrast = 0; settings.detail = 0
        let result = try HDRToneMapper.render(image, settings: settings)
        XCTAssertEqual(result.rgb, [0.2,0.4,0.8])
        XCTAssertEqual(image.rgb, [0.1,0.2,0.4])
    }

    func testFusionAndTextureRemainFiniteOnConstantAndExtremeInputs() throws {
        for value: Float in [0, 0.000001, 0.18, 1, 16] {
            let image = try HDRImage(width: 7, height: 5, rgb: Array(repeating: value, count: 105))
            var settings = HDRSettings(); settings.method = .virtualExposureFusion
            settings.detail = 1; settings.microcontrast = 1
            let output = try HDRToneMapper.render(image, settings: settings)
            XCTAssertTrue(output.rgb.allSatisfy { $0.isFinite && $0 >= 0 })
            XCTAssertLessThan((output.rgb.max() ?? 0) - (output.rgb.min() ?? 0), 0.00001)
        }
    }

    func testRejectsInvalidImagesSettingsAndHonorsCancellation() throws {
        XCTAssertThrowsError(try HDRImage(width: 0, height: 1, rgb: []))
        XCTAssertThrowsError(try HDRImage(width: 1, height: 1, rgb: [.nan,0,0]))
        let image = try HDRImage(width: 1, height: 1, rgb: [1,1,1])
        var settings = HDRSettings(); settings.detail = .infinity
        XCTAssertThrowsError(try HDRToneMapper.render(image, settings: settings))
        XCTAssertThrowsError(try HDRToneMapper.render(image, settings: HDRSettings(), cancellation: { throw CancellationError() }))
    }
}
