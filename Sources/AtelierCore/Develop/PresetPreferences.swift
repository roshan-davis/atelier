import Foundation

/// App preferences that name built-in preset packs: which packs are hidden
/// (`presets.hiddenGroups`, pack names) and which groups the Presets panel shows
/// toggled open or closed (`presets.toggledGroups`, "pack:<name>" / "user:<name>", one per line).
///
/// Both store the pack's display name, so renaming a pack must carry these entries over.
/// The built-in pack "Atelier" became "Lightfast" when the app was renamed (Oct 31, 2026).
public enum PresetPreferences {
    public static let hiddenGroupsKey = "presets.hiddenGroups"
    public static let toggledGroupsKey = "presets.toggledGroups"
    /// Set once the renames below have been applied, so they run a single time.
    static let migratedKey = "presets.packRenames.v1"

    /// Old built-in pack name → new one.
    public static let renamedPacks = ["Atelier": "Lightfast"]

    /// Hidden pack names with renamed packs under their new names. Hiding applies only to
    /// built-in packs (a user group with the same name is never hidden), so every entry is a pack.
    public static func migratedHiddenGroups(_ names: [String]) -> [String] {
        unique(names.map { renamedPacks[$0] ?? $0 })
    }

    /// Toggled group IDs with renamed packs under their new names. Only exact "pack:" entries
    /// change; user groups ("user:<name>") keep their names.
    public static func migratedToggledGroups(_ list: String) -> String {
        let ids = list.split(separator: "\n").map { line -> String in
            let id = String(line)
            guard id.hasPrefix("pack:"), let new = renamedPacks[String(id.dropFirst(5))] else { return id }
            return "pack:" + new
        }
        return unique(ids).sorted().joined(separator: "\n")
    }

    /// Applies the renames to `defaults` once. Call before either preference is read.
    public static func migrate(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        if let hidden = defaults.stringArray(forKey: hiddenGroupsKey) {
            defaults.set(migratedHiddenGroups(hidden).sorted(), forKey: hiddenGroupsKey)
        }
        if let toggled = defaults.string(forKey: toggledGroupsKey) {
            defaults.set(migratedToggledGroups(toggled), forKey: toggledGroupsKey)
        }
        defaults.set(true, forKey: migratedKey)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
