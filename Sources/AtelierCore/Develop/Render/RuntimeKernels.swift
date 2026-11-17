import CoreImage
import Foundation

/// Builds Core Image kernels from Metal source at run time.
enum RuntimeKernels {
    /// Builds every `[[stitchable]]` kernel in `source`, each from its own copy of the source's
    /// header (everything before the first kernel: includes and helper functions). With several
    /// kernels in one library Core Image mixes up their argument lists at render time and the
    /// app aborts ("Argument count mismatch for program ci_<kernel>"). Nil if any fails to build.
    static func build(_ source: String) -> [String: CIKernel]? {
        let marker = "[[stitchable]]"
        let parts = source.components(separatedBy: marker)
        guard parts.count > 1 else { return nil }
        var kernels = [String: CIKernel]()
        for body in parts.dropFirst() {
            guard let kernel = (try? CIKernel.kernels(withMetalString: parts[0] + marker + body))?.first else { return nil }
            kernels[kernel.name] = kernel
        }
        return kernels.count == parts.count - 1 ? kernels : nil
    }
}
