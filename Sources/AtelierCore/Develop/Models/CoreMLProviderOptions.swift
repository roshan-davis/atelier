import Foundation

/// The options every ONNX model (Depth Range, Fine Edges, AI Denoise) passes to ONNX Runtime's
/// Core ML execution provider, in one place.
///
/// ONNX Runtime accepts only `CPUOnly`, `CPUAndGPU`, `CPUAndNeuralEngine` and `ALL` for
/// `MLComputeUnits` (onnxruntime/core/providers/coreml/coreml_options.cc). Until Nov 16, 2026
/// each model asked for `All`, which ONNX Runtime refuses, so every one of them quietly fell
/// back to the CPU ("Depth Range with Core ML failed … Invalid value for option
/// `MLComputeUnits`: All", in Rosh's test run).
enum CoreMLProviderOptions {
    static let computeUnits = "ALL"

    static func options(cache: URL) -> [String: String] {
        ["ModelFormat": "MLProgram", "MLComputeUnits": computeUnits, "ModelCacheDirectory": cache.path]
    }
}
