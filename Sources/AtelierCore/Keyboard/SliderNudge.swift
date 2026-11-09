import Foundation

/// How far one arrow-key press moves a Develop slider: 1/200 of the track, or 1/40 with ⇧,
/// rounded to the slider's step and never less than one step.
public enum SliderNudge {
    public static let smallFraction = 0.005
    public static let largeFraction = 0.025

    /// `direction` is +1 (→ or ↑) or -1 (← or ↓).
    public static func value(from value: Double, range: ClosedRange<Double>, step: Double,
                             logarithmic: Bool = false, direction: Int, large: Bool) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, direction != 0 else { return value }
        let sign = direction > 0 ? 1.0 : -1.0
        let fraction = large ? largeFraction : smallFraction
        let current = min(max(value, range.lowerBound), range.upperBound)
        var next: Double
        if logarithmic, range.lowerBound > 0 {
            let low = log(range.lowerBound), high = log(range.upperBound)
            let position = (log(current) - low) / (high - low) + sign * fraction
            next = exp(low + min(1, max(0, position)) * (high - low))
        } else {
            next = current + sign * fraction * span
        }
        if step > 0 {
            next = (next / step).rounded() * step
            if next == current { next = current + sign * step }
        }
        return min(max(next, range.lowerBound), range.upperBound)
    }
}
