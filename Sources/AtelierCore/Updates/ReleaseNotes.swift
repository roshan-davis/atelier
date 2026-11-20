import Foundation

/// Atelier's changelog (AT-087): `Sources/AtelierApp/Resources/ReleaseNotes.md`, the one place
/// release notes are written. The What's New window reads it from the app, and the release
/// script copies each version's section into the appcast for Sparkle's update window.
///
///     # Release notes            (anything before the first version is ignored)
///     ## 1.3.0 (2026-11-20)
///     A sentence or two about the release.
///     ### New
///     - Settings > Updates: check for updates and install them on quit.
///     ### Fixed
///     - Crop: straighten no longer leaves streaks.
public struct ReleaseNotes: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        /// "New", "Improved", "Fixed"; empty for bullets before any heading.
        public var title: String
        public var items: [String]
    }

    public struct Release: Sendable, Equatable, Identifiable {
        public var version: AppVersion
        /// The date in the heading, as written ("2026-11-20"); nil when left out.
        public var date: String?
        /// Paragraph text under the version heading, before its first section.
        public var summary: String
        public var sections: [Section]

        public var id: String { version.description }
    }

    /// Newest first, whatever order the file has.
    public let releases: [Release]

    public init(releases: [Release]) {
        self.releases = releases.sorted { $0.version > $1.version }
    }

    /// Reads the changelog's Markdown. Lines it doesn't understand are kept as summary text.
    public init(markdown: String) {
        var releases: [Release] = []
        var current: Release?
        var inComment = false
        func finish() { if let current { releases.append(current) } }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // <!-- notes for whoever writes the changelog --> are skipped.
            if inComment || line.hasPrefix("<!--") {
                inComment = !line.contains("-->")
                continue
            }
            if line.hasPrefix("## ") && !line.hasPrefix("### ") {
                finish()
                current = Self.release(fromHeading: String(line.dropFirst(3)))
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("### ") {
                current!.sections.append(Section(title: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces), items: []))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if current!.sections.isEmpty { current!.sections.append(Section(title: "", items: [])) }
                current!.sections[current!.sections.count - 1].items.append(item)
            } else if !line.isEmpty, raw.hasPrefix("  "), let last = current!.sections.indices.last,
                      !current!.sections[last].items.isEmpty {
                // A wrapped bullet: an indented line continues the item above it.
                let index = current!.sections[last].items.count - 1
                current!.sections[last].items[index] += " " + line
            } else if !line.isEmpty, current!.sections.isEmpty {
                current!.summary += (current!.summary.isEmpty ? "" : " ") + line
            }
        }
        finish()
        self.init(releases: releases)
    }

    /// "1.3.0 (2026-11-20)", "1.3.0 — 2026-11-20", "v1.3.0" or "[1.3.0] - 2026-11-20".
    private static func release(fromHeading heading: String) -> Release? {
        let cleaned = heading.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        let words = cleaned.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" })
            .map(String.init).filter { $0 != "—" && $0 != "-" && $0 != "–" }
        guard let first = words.first, let version = AppVersion(first) else { return nil }
        return Release(version: version, date: words.dropFirst().first, summary: "", sections: [])
    }

    public func release(_ version: AppVersion) -> Release? {
        releases.first { $0.version == version }
    }

    /// What's New after an update: every release newer than `lastSeen` up to `current`,
    /// newest first. Pre-releases are left out unless `current` is one (a beta tester sees betas).
    public func releases(after lastSeen: AppVersion, upTo current: AppVersion) -> [Release] {
        releases.filter { $0.version > lastSeen && $0.version <= current && (!$0.version.isPrerelease || current.isPrerelease) }
    }

    /// One release as Markdown again, for the appcast (`<description sparkle:format="markdown">`).
    public static func markdown(for release: Release) -> String {
        var lines: [String] = []
        if !release.summary.isEmpty { lines += [release.summary, ""] }
        for section in release.sections {
            if !section.title.isEmpty { lines.append("### " + section.title) }
            lines += section.items.map { "- " + $0 }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decides when the What's New window opens by itself (AT-087): once, on the first launch of a
/// newer version than the one last used. A fresh install (nothing remembered) and a downgrade
/// show nothing; either way the current version is remembered.
public enum WhatsNewSchedule {
    public static let lastSeenKey = "updates.lastSeenVersion"

    /// The releases to show now, or nil to show nothing. Call once per launch; it remembers `current`.
    public static func releasesToShow(current: AppVersion, notes: ReleaseNotes,
                                      defaults: UserDefaults = .standard) -> [ReleaseNotes.Release]? {
        let stored = defaults.string(forKey: lastSeenKey).flatMap(AppVersion.init)
        defaults.set(current.description, forKey: lastSeenKey)
        guard let stored, current > stored else { return nil }
        let releases = notes.releases(after: stored, upTo: current)
        return releases.isEmpty ? nil : releases
    }
}
