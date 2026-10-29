import Foundation

/// Lightroom's panel switches: every Develop panel but Basic can be turned off from its header
/// to compare, keeping its settings. One mechanism for all of them: the renderer, the lens
/// geometry and anything else that reads settings for their effect go through
/// `applyingPanelSwitches()`, so a panel never needs its own "off" handling.
extension DevelopSettings {
    public func isOn(_ panel: Panel) -> Bool { !disabledPanels.contains(panel) }

    public mutating func setPanel(_ panel: Panel, on: Bool) {
        guard panel.hasSwitch else { return }
        if on { disabledPanels.remove(panel) } else { disabledPanels.insert(panel) }
    }

    /// These settings as they take effect: every panel that is off reads as if it did nothing.
    /// The switches themselves are dropped, so applying this twice changes nothing.
    public func applyingPanelSwitches() -> DevelopSettings {
        guard !disabledPanels.isEmpty else { return self }
        var result = self
        for panel in disabledPanels { result.removeEffect(of: panel) }
        result.disabledPanels = []
        return result
    }

    /// Takes away everything `panel` does. Not the same as resetting it: Lens Corrections'
    /// profile corrections are on by default, but off here.
    private mutating func removeEffect(of panel: Panel) {
        switch panel {
        case .toneCurve:
            for channel in CurveChannel.allCases { setPoints([], for: channel) }
        case .lensCorrections:
            lensProfileCorrections = false
            removeChromaticAberration = false
        case .transform:
            // The crop Constrain Crop chose stays, as in Lightroom.
            upright = nil
        default:
            break
        }
        for parameter in panel.parameters where parameter != .temperature {
            self[parameter] = parameter.defaultValue
        }
    }

    /// Everything a panel holds, to tell whether an edit touched it.
    public struct PanelContents: Hashable {
        var values: [Double]
        var curves: [[CurvePoint]] = []
        var flags: [Bool] = []
        var upright: Upright?
    }

    public func contents(of panel: Panel) -> PanelContents {
        var contents = PanelContents(values: panel.parameters.map { self[$0] })
        switch panel {
        case .toneCurve:
            contents.curves = CurveChannel.allCases.map { points(for: $0) }
        case .lensCorrections:
            contents.flags = [lensProfileCorrections, removeChromaticAberration]
        case .transform:
            contents.flags = [constrainCrop]
            contents.upright = upright
        default:
            break
        }
        return contents
    }
}
