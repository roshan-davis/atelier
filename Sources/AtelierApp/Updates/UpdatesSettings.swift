import AppKit
import AtelierCore
import SwiftUI

/// Settings > Updates (AT-087): this copy's version, the last check and Check Now, and how
/// updates arrive. Values live in Sparkle's own user defaults, so its update window and this
/// pane always agree.
struct UpdatesSettings: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            SettingsSection("Atelier") {
                LabeledContent("Version", value: AppUpdater.currentVersionText)
                if updater.isEnabled {
                    LabeledContent("Last checked", value: lastCheckText)
                }
                HStack {
                    if updater.isEnabled {
                        Button(updater.pendingVersion == nil ? "Check Now" : "Show Update…") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    }
                    Button("What’s New in Atelier…") { WhatsNewWindow.shared.showAll() }
                    if let pending = updater.pendingVersion {
                        Text("Atelier \(pending) is available.")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(updater.isEnabled
                     ? "New versions come from Atelier’s releases on GitHub. Each one is checked against Atelier’s signature before it’s installed. Nothing about you or your photos is sent."
                     : "Updates are off in builds run from Xcode. Copies built with Scripts/release/make_release.py check for updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if updater.isEnabled {
                SettingsSection("Automatic Updates") {
                    Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                    Toggle("Download and install updates automatically", isOn: $updater.installsAutomatically)
                        .disabled(!updater.allowsAutomaticInstall || !updater.checksAutomatically)
                    Toggle("Include beta versions", isOn: Binding(get: { updater.includesBeta },
                                                                  set: { updater.includesBeta = $0 }))
                } footer: {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return "Never" }
        if Calendar.current.isDateInToday(date) { return "Today at \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday at \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var footer: String {
        var text = "Atelier checks once a day. Bug-fix and feature updates download in the background and install when you quit, so nothing interrupts your work. A major version (2.0, 3.0) always asks first, because it upgrades the catalog; the catalog is backed up before that."
        if !updater.allowsAutomaticInstall {
            text += " This copy isn’t signed with a Developer ID, so updates install when you choose Install in the update window."
        }
        text += " Beta versions are previews of the next release and may have rough edges."
        return text
    }
}
