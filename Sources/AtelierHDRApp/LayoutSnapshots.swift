import AppKit
import SwiftUI

/// HDR states participate in the same opt-in snapshot convention as Lightfast's LayoutSnapshots.
/// Only disposable app launches should set ATELIER_HDR_SNAPSHOTS.
@MainActor enum LayoutSnapshots {
    static func run(editor: HDRController, into folder: URL) async {
        for _ in 0..<300 where editor.after == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard editor.after != nil else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for theme in [Theme.light, .graphite] {
            theme.apply()
            for (name, size, compare) in [
                ("minimum-split", CGSize(width: 1100, height: 680), "Split"),
                ("large-side-by-side", CGSize(width: 1280, height: 800), "Side by Side")
            ] {
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSApp.appearance
                let host = NSHostingView(rootView: HDRWorkspace(editor: editor, compare: compare).environment(\.theme, theme)
                    .background(Color(nsColor: theme.chrome)))
                window.contentView = host; window.setContentSize(size); window.orderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("hdr-\(theme.rawValue)-\(name).png"))
                }
                window.orderOut(nil)
            }
        }
    }
}
