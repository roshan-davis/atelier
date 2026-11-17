import AtelierCore
import SwiftUI

/// A setting kept in UserDefaults: its key and its default, written once (AT-076 E2). Settings
/// read in more than one place use one of these, so every reader agrees on the default.
struct Preference<Value: Sendable>: Sendable {
    let key: String
    let defaultValue: Value
}

/// The settings that more than one part of the app reads.
enum Preferences {
    static let xmpAutoWrite = Preference(key: "xmp.autoWrite", defaultValue: false)
    static let backupsToKeep = Preference(key: "backups.keep", defaultValue: 10)
    static let clickZoomPercent = Preference(key: "zoom.clickPercent", defaultValue: 100.0)
    static let showClipping = Preference(key: "develop.showClipping", defaultValue: true)
    static let soloMode = Preference(key: "develop.soloMode", defaultValue: false)
    static let expandedPanels = Preference(key: "develop.expandedPanels", defaultValue: "histogram,basic")
    static let importCopies = Preference(key: "import.copy", defaultValue: false)
    static let importDestination = Preference(key: "import.destination", defaultValue: picturesFolder("Atelier Library"))
    static let exportDestination = Preference(key: "export.destination", defaultValue: picturesFolder("Atelier Exports"))
    static let exportReveals = Preference(key: "export.reveal", defaultValue: true)
    static let aiServer = Preference(key: "ai.server", defaultValue: AISettings.defaultServer.absoluteString)
    static let aiEditModel = Preference(key: "ai.editModel", defaultValue: "")
    static let aiUpscaleModel = Preference(key: "ai.upscaleModel", defaultValue: "")
    static let aiGenerationSize = Preference(key: "ai.generationSize", defaultValue: 1024)
    static let aiUpscaleFactor = Preference(key: "ai.upscaleFactor", defaultValue: 2)

    private static func picturesFolder(_ name: String) -> String {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent(name).path
    }
}

extension UserDefaults {
    /// The stored value, or the preference's default when none is stored (or it has another type).
    func value<Value>(_ preference: Preference<Value>) -> Value {
        object(forKey: preference.key) as? Value ?? preference.defaultValue
    }

    func set<Value>(_ value: Value, for preference: Preference<Value>) {
        set(value, forKey: preference.key)
    }
}

extension AppStorage where Value == Bool {
    init(_ preference: Preference<Bool>) { self.init(wrappedValue: preference.defaultValue, preference.key) }
}

extension AppStorage where Value == Int {
    init(_ preference: Preference<Int>) { self.init(wrappedValue: preference.defaultValue, preference.key) }
}

extension AppStorage where Value == Double {
    init(_ preference: Preference<Double>) { self.init(wrappedValue: preference.defaultValue, preference.key) }
}

extension AppStorage where Value == String {
    init(_ preference: Preference<String>) { self.init(wrappedValue: preference.defaultValue, preference.key) }
}
