import Foundation
import XCTest
@testable import AtelierCore

/// The Core ML options the ONNX models share: ONNX Runtime refuses any other spelling of the
/// compute units, and a refused option silently moves the model to the CPU (Nov 16, 2026).
final class CoreMLProviderOptionsTests: XCTestCase {
    func testComputeUnitsAreASpellingONNXRuntimeAccepts() {
        let accepted: Set<String> = ["CPUOnly", "CPUAndGPU", "CPUAndNeuralEngine", "ALL"]
        let options = CoreMLProviderOptions.options(cache: URL(fileURLWithPath: "/tmp/cache"))
        XCTAssertTrue(accepted.contains(options["MLComputeUnits"] ?? ""), "\(options)")
        XCTAssertEqual(options["MLComputeUnits"], "ALL", "the GPU and Neural Engine as well as the CPU")
        XCTAssertEqual(options["ModelFormat"], "MLProgram")
        XCTAssertEqual(options["ModelCacheDirectory"], "/tmp/cache")
    }
}
