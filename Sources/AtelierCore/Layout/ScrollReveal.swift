import Foundation

/// Keyboard navigation in a scrolling list or row, as in Finder and Lightroom's grid: the list
/// only moves when the selected item is not fully visible, and then by the least that shows it.
public enum ScrollReveal {
    /// The scroll offset along one axis that brings an item fully into view, or nil when it is
    /// already fully visible and the list should stay where it is.
    ///
    /// - Parameters:
    ///   - item: the item's start and end, in content coordinates.
    ///   - visibleStart: the current offset; `visibleLength` how much of the content shows.
    ///   - contentLength: the content's full length, so the offset never runs past the end.
    ///   - margin: room left beside the item when the list does move.
    public static func offset(item: ClosedRange<Double>, visibleStart: Double, visibleLength: Double,
                              contentLength: Double, margin: Double = 0) -> Double? {
        let visibleEnd = visibleStart + visibleLength
        if item.lowerBound >= visibleStart - 0.5, item.upperBound <= visibleEnd + 0.5 { return nil }
        let target: Double
        if item.lowerBound < visibleStart || item.upperBound - item.lowerBound + 2 * margin >= visibleLength {
            // Above (or bigger than) the view: its start goes to the top.
            target = item.lowerBound - margin
        } else {
            // Below: its end goes to the bottom.
            target = item.upperBound + margin - visibleLength
        }
        return min(max(target, 0), max(contentLength - visibleLength, 0))
    }
}
