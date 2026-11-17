/// The one tool open over Develop's photo (AT-076 D1). At most one is open; Lens Blur's Refine
/// is nested in Lens Blur (Masking's tools on Lens Blur's own areas), so it is part of that case
/// rather than a second tool open alongside. The old flags (`isCropping`, `isMasking`, ...) read
/// and write this; `DevelopController.switchTool(to:)` does what opening and closing each one
/// takes.
enum DevelopTool: Hashable, Sendable {
    case crop
    case ai
    case masking
    case guidedUpright
    case remove
    case lensBlur(refining: Bool)

    var isLensBlur: Bool {
        if case .lensBlur = self { return true }
        return false
    }

    /// Masking's tools are out: the Masking tool, or Lens Blur's Refine.
    var masks: Bool { self == .masking || self == .lensBlur(refining: true) }

    /// The tool without what's nested in it, to tell opening a tool from moving inside one.
    var root: DevelopTool { isLensBlur ? .lensBlur(refining: false) : self }
}
