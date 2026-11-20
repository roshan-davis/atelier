import AppKit
import AtelierCore
import SwiftUI

/// What's New in Atelier (AT-087): the release notes from `Resources/ReleaseNotes.md`, in their
/// own window. Opens by itself once on the first launch after an update (every version since the
/// one last used), and from Help > What's New in Atelier and Settings > Updates any time.
@MainActor
final class WhatsNewWindow {
    static let shared = WhatsNewWindow()

    private var window: NSWindow?

    /// The changelog bundled with the app; empty if it's missing.
    static var notes: ReleaseNotes {
        guard let url = AtelierResources.bundle.url(forResource: "ReleaseNotes", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ReleaseNotes(releases: []) }
        return ReleaseNotes(markdown: text)
    }

    /// At launch, once the library shows: opens the window if this is the first launch of a newer
    /// version. Never in builds run from Xcode (no version) or in snapshot and smoke-test runs.
    func showAfterUpdateIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app", let current = AppVersion.current() else { return }
        #if DEBUG
        if LayoutSnapshots.outputFolder != nil || ProcessInfo.processInfo.environment["ATELIER_UI_SMOKE"] != nil { return }
        #endif
        let previous = UserDefaults.standard.string(forKey: WhatsNewSchedule.lastSeenKey)
        guard let releases = WhatsNewSchedule.releasesToShow(current: current, notes: Self.notes) else { return }
        show(WhatsNewContent(current: current, previous: previous.flatMap(AppVersion.init), releases: releases))
    }

    /// Help > What's New in Atelier: every release, newest first.
    func showAll() {
        let notes = Self.notes
        let current = AppVersion.current()
        let releases = notes.releases.filter { release in
            guard let current else { return true }
            return release.version <= current && (!release.version.isPrerelease || current.isPrerelease)
        }
        show(WhatsNewContent(current: current ?? releases.first?.version, previous: nil, releases: releases))
    }

    func show(_ content: WhatsNewContent) {
        let view = WhatsNewView(content: content) { [weak self] in self?.window?.close() }
        if let window {
            window.contentView = NSHostingView(rootView: view)
            window.title = content.windowTitle
        } else {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: WhatsNewView.size.width, height: WhatsNewView.size.height),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = content.windowTitle
            window.isReleasedWhenClosed = false
            window.minSize = CGSize(width: 460, height: 420)
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.setFrameAutosaveName("AtelierWhatsNew")
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the window shows: the releases, and the versions it's between.
struct WhatsNewContent {
    var current: AppVersion?
    /// The version used before this update; nil when opened from the menu.
    var previous: AppVersion?
    var releases: [ReleaseNotes.Release]

    var windowTitle: String { "What’s New in Atelier" }

    var heading: String {
        guard let current else { return "What’s New in Atelier" }
        return "What’s New in Atelier \(current.shortDescription)"
    }

    var subheading: String? {
        guard let previous, let current else { return nil }
        switch UpdateKind(from: previous, to: current) {
        case .major: return "Updated from \(previous.shortDescription). Your catalog was backed up before it was upgraded."
        default: return "Updated from \(previous.shortDescription)."
        }
    }
}

struct WhatsNewView: View {
    static let size = CGSize(width: 580, height: 640)

    let content: WhatsNewContent
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if content.releases.isEmpty {
                        Text("No release notes in this build.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(content.releases) { release in
                        WhatsNewRelease(release: release, isLatest: release.id == content.releases.first?.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Atelier Help") { HelpWindow.shared.show(page: "updates") }
                Spacer()
                Button("Continue", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(content.heading)
                    .font(.title.weight(.semibold))
                if let subheading = content.subheading {
                    Text(subheading)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }
}

/// One version: "1.3 · November 20, 2026", its summary, then New, Improved and Fixed.
private struct WhatsNewRelease: View {
    let release: ReleaseNotes.Release
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Atelier \(release.version.shortDescription)")
                    .font(.title3.weight(.semibold))
                if let date = Self.date(release.date) {
                    Text(date).font(.callout).foregroundStyle(.secondary)
                }
                if release.version.isPrerelease {
                    Text("Beta")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(SettingsPalette.butter.opacity(0.35)))
                }
            }
            if !release.summary.isEmpty {
                Text(LocalizedStringKey(release.summary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(release.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 6) {
                    if !section.title.isEmpty {
                        Text(section.title.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Self.tint(section.title))
                            .kerning(0.6)
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").fontWeight(.bold).foregroundStyle(Self.tint(section.title))
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(item))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// New is green, Improved blue, Fixed orange, as tags in release notes usually are, from the
    /// same soft palette as Settings.
    static func tint(_ title: String) -> Color {
        switch title.lowercased() {
        case "new", "added": return SettingsPalette.sage
        case "improved", "changed": return SettingsPalette.sky
        case "fixed": return SettingsPalette.peach
        default: return .secondary
        }
    }

    /// "2026-11-20" as "November 20, 2026"; other text as written.
    static func date(_ text: String?) -> String? {
        guard let text else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: text) else { return text }
        return date.formatted(date: .long, time: .omitted)
    }
}
