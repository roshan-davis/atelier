import Foundation

/// Atelier's one slider, in numbers (Rosh, Nov 10, 2026): every slider in the app draws and
/// handles its knob with these, so they all look and work the same. The views are
/// `DevelopSlider` and `HueRangeSlider`; this is the math they share, kept here so it can be
/// tested without a window.
///
/// - The knob is 12 pt, a little bigger than Lightroom's, but it can be caught anywhere in a
///   20 pt zone around it: a press there picks the knob up where it is, with no jump.
/// - A press elsewhere on the track jumps the knob there, as in Lightroom, and the drag goes on
///   from there.
/// - The track is inset by the knob's radius, so the knob never hangs over the slider's name or
///   value at either end and all of it can be grabbed.
public enum SliderGeometry {
    public static let knobDiameter = 12.0
    /// How wide (and tall) the zone is where a press picks the knob up instead of jumping.
    public static let grabZone = 20.0
    public static let trackHeight = 3.0
    /// A slider's own height, so the grab zone fits inside it.
    public static let height = 20.0
    public static var trackInset: Double { knobDiameter / 2 }

    /// The usable track length in a slider `width` points wide.
    public static func trackLength(width: Double) -> Double { max(0, width - 2 * trackInset) }

    /// Where on the slider (0...width) the knob's center sits for `fraction` (0...1).
    public static func x(fraction: Double, width: Double) -> Double {
        trackInset + min(1, max(0, fraction)) * trackLength(width: width)
    }

    /// The fraction (0...1) for a point `x` along a slider `width` points wide.
    public static func fraction(x: Double, width: Double) -> Double {
        let length = trackLength(width: width)
        guard length > 0 else { return 0 }
        return min(1, max(0, (x - trackInset) / length))
    }

    /// Whether a press at `x` is on the knob centered at `knobX` (inside its grab zone).
    public static func isOnKnob(_ x: Double, knobX: Double) -> Bool {
        abs(x - knobX) <= grabZone / 2
    }

    /// How far to shift the pointer for the rest of a drag that starts at `x`: on the knob, the
    /// knob keeps its place under the pointer (no jump); elsewhere the knob jumps to the pointer.
    public static func grabOffset(start x: Double, knobX: Double) -> Double {
        isOnKnob(x, knobX: knobX) ? knobX - x : 0
    }

    /// A value's place along the track (0...1). Temperature uses a logarithmic track, so equal
    /// moves are equal steps of perceived warmth rather than Kelvin.
    public static func fraction(of value: Double, in range: ClosedRange<Double>, logarithmic: Bool = false) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if logarithmic, range.lowerBound > 0 {
            return (log(clamped) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound))
        }
        return (clamped - range.lowerBound) / span
    }

    /// The value at `fraction` along the track, rounded to `step` (no rounding when it is 0).
    public static func value(at fraction: Double, in range: ClosedRange<Double>, step: Double,
                             logarithmic: Bool = false) -> Double {
        let f = min(1, max(0, fraction))
        let raw = logarithmic && range.lowerBound > 0
            ? exp(log(range.lowerBound) + f * (log(range.upperBound) - log(range.lowerBound)))
            : range.lowerBound + f * (range.upperBound - range.lowerBound)
        let rounded = step > 0 ? (raw / step).rounded() * step : raw
        return min(max(rounded, range.lowerBound), range.upperBound)
    }
}
