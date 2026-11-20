import Foundation

/// Atelier's version, `MAJOR.MINOR.PATCH` with an optional pre-release tag (`1.3.0-beta.2`),
/// compared the semantic-versioning way (AT-087): a pre-release comes before its release.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// "beta.2" for 1.3.0-beta.2; nil for a release.
    public let prerelease: String?

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Reads "1", "1.3", "1.3.0", "v1.3.0" or "1.3.0-beta.2"; nil for anything else.
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count) else { return nil }
        var values: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber),
                  let value = Int(number) else { return nil }
            values.append(value)
        }
        while values.count < 3 { values.append(0) }
        let tag = parts.count > 1 ? String(parts[1]) : nil
        if let tag, tag.isEmpty { return nil }
        self.init(values[0], values[1], values[2], prerelease: tag)
    }

    /// The running app's version, from its Info.plist; nil when run from Xcode (no bundle).
    public static func current(in bundle: Bundle = .main) -> AppVersion? {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    public var isPrerelease: Bool { prerelease != nil }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-" + $0 } ?? "")
    }

    /// "1.3" for 1.3.0, "1.3.1" for 1.3.1: the short form people read in titles.
    public var shortDescription: String {
        let base = patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        return base + (prerelease.map { " " + $0.replacingOccurrences(of: ".", with: " ") } ?? "")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (l?, r?): return Self.prereleaseLess(l, r)
        }
    }

    /// semver 11.4: dot-separated identifiers, numbers compare as numbers and before words.
    private static func prereleaseLess(_ lhs: String, _ rhs: String) -> Bool {
        let l = lhs.split(separator: "."), r = rhs.split(separator: ".")
        for (a, b) in zip(l, r) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return l.count < r.count
    }
}

/// How big a step from one version to another is (AT-087). Patch: fixes, installs silently.
/// Minor: features, installs automatically and shows What's New. Major: may change the catalog
/// so an older Atelier can't read it; never installed without asking.
public enum UpdateKind: String, Sendable {
    case none, patch, minor, major

    public init(from old: AppVersion, to new: AppVersion) {
        if new <= old { self = .none }
        else if new.major != old.major { self = .major }
        else if new.minor != old.minor { self = .minor }
        else { self = .patch }
    }

    /// Whether this step may install without asking (when automatic install is on).
    public var installsWithoutAsking: Bool { self == .patch || self == .minor }
}
