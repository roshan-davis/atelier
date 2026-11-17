import Foundation

/// The Presets panel's Recent group: the presets applied most recently, newest first.
/// Atelier keeps their IDs (as an app preference), so a renamed preset stays in the list and a
/// deleted or hidden one simply drops out.
public enum RecentPresets {
    /// How many presets the Recent group lists.
    public static let limit = 6

    /// `ids` with `id` moved (or added) to the front, without repeats, at most `limit` long.
    public static func adding(_ id: UUID, to ids: [UUID], limit: Int = limit) -> [UUID] {
        Array(([id] + ids.filter { $0 != id }).prefix(limit))
    }

    /// The presets for `ids`, in that order, skipping any no longer in `presets`.
    public static func presets(_ ids: [UUID], in presets: [DevelopPreset]) -> [DevelopPreset] {
        let byID = Dictionary(presets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}
