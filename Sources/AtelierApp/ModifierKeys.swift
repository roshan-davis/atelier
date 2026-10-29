import AppKit

/// Whether ⌥ is held, for views that change while it is, such as Lightroom's group headings
/// that read "Reset Tone" with ⌥ down. One shared event monitor, installed on first use.
@MainActor
final class ModifierKeys: ObservableObject {
    static let shared = ModifierKeys()

    @Published private(set) var option = false
    private var monitor: Any?

    private init() {
        option = NSEvent.modifierFlags.contains(.option)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated {
                if self?.option != held { self?.option = held }
            }
            return event
        }
        // ⌥ let go in another app never reaches us.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.option = false }
        }
    }
}
