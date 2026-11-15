import AtelierCore
import Foundation

/// What a set of Color Grading wheels edits: the photo's Color Grading panel, or one mask's own
/// Color Grading (Lightroom Classic 16). The same wheels, sliders and menus serve both, so they
/// look and work the same (AGENTS.md "Solve a pattern once").
enum GradeTarget: Hashable {
    case photo
    case mask(UUID)
}

extension DevelopController {
    typealias GradeRegion = DevelopSettings.GradeRegion

    /// A Color Grading value for `target`.
    func gradeValue(_ parameter: DevelopSettings.Parameter, in target: GradeTarget) -> Double {
        switch target {
        case .photo: return value(parameter)
        case .mask(let id): return masks.first { $0.id == id }?[grade: parameter] ?? parameter.defaultValue
        }
    }

    func setGrade(_ parameter: DevelopSettings.Parameter, to value: Double, in target: GradeTarget) {
        switch target {
        case .photo:
            set(parameter, to: value)
        case .mask(let id):
            updateMask(id, step: "\(Self.parameterName(parameter)) \(Int(value.rounded()))") { $0[grade: parameter] = value }
        }
    }

    /// A wheel's hue and saturation together, as one history step.
    func setGradeColor(_ region: GradeRegion, hue: Double, saturation: Double, in target: GradeTarget) {
        switch target {
        case .photo:
            setGradeColor(region, hue: hue, saturation: saturation)
        case .mask(let id):
            updateMask(id, step: "Color Grading \(region.rawValue) \(Int(hue.rounded()))°, \(Int(saturation.rounded()))") {
                $0[grade: region.hue] = hue
                $0[grade: region.saturation] = saturation
            }
        }
    }

    /// Resets a wheel's hue and saturation, and with `luminance` its Luminance too.
    func resetGrade(_ region: GradeRegion, luminance: Bool, in target: GradeTarget) {
        switch target {
        case .photo:
            resetGrade(region, luminance: luminance)
        case .mask:
            var parameters = [region.hue, region.saturation]
            if luminance { parameters.append(region.luminance) }
            resetGrade(parameters, name: "Color Grading \(region.rawValue)", in: target)
        }
    }

    /// Resets `parameters` as one step named "Reset `name`".
    func resetGrade(_ parameters: [DevelopSettings.Parameter], name: String, in target: GradeTarget) {
        switch target {
        case .photo:
            if parameters.count == 1, let only = parameters.first {
                reset(only)
            } else {
                reset(group: name, parameters: parameters)
            }
        case .mask(let id):
            updateMask(id, step: "Reset \(name)") { mask in
                for parameter in parameters { mask[grade: parameter] = parameter.defaultValue }
            }
        }
    }

    /// Resets all of the target's Color Grading.
    func resetAllGrade(in target: GradeTarget) {
        switch target {
        case .photo: reset(.colorGrading)
        case .mask(let id): updateMask(id, step: "Reset Color Grading") { $0.resetGrade() }
        }
    }

    func copyGradeWheel(_ region: GradeRegion, in target: GradeTarget) {
        copyGradeWheel(GradeWheelValues(hue: gradeValue(region.hue, in: target),
                                        saturation: gradeValue(region.saturation, in: target),
                                        luminance: gradeValue(region.luminance, in: target)))
    }

    func pasteGradeWheel(onto region: GradeRegion, in target: GradeTarget) {
        switch target {
        case .photo:
            pasteGradeWheel(onto: region)
        case .mask(let id):
            guard let copied = copiedGradeWheel else { return }
            updateMask(id, step: "Paste Color Grading \(region.rawValue)") { mask in
                mask[grade: region.hue] = copied.hue
                mask[grade: region.saturation] = copied.saturation
                mask[grade: region.luminance] = copied.luminance
            }
        }
    }

    /// Arrow keys over a wheel: Left and Right turn the hue, Up and Down change saturation.
    func nudgeGrade(_ region: GradeRegion, hue: Double, saturation: Double, in target: GradeTarget) {
        var newHue = (gradeValue(region.hue, in: target) + hue).truncatingRemainder(dividingBy: 360)
        if newHue < 0 { newHue += 360 }
        let newSaturation = min(100, max(0, gradeValue(region.saturation, in: target) + saturation))
        setGradeColor(region, hue: newHue, saturation: newSaturation, in: target)
    }
}
