import AppKit
import SwiftUI

/// The sound and puff of smoke when something is deleted: Finder's Trash sound when files go
/// to the Trash, the Dock's poof when something is removed from Atelier (a mask, preset, guide,
/// snapshot, collection, or photos taken out of the catalog). Every delete calls `play`, so
/// they all sound and look the same. Settings > General can turn it off; the sound also follows
/// System Settings > Sound > "Play user interface sound effects", and the puff Reduce Motion.
@MainActor
enum DeleteFeedback {
    enum Kind {
        /// Files moved to the Trash.
        case trash
        /// Something removed from Atelier; no file is touched.
        case remove
    }

    static let enabledKey = "feedback.deleteEffects"

    static func play(_ kind: Kind) {
        guard UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true else { return }
        playSound(kind)
        showPoof()
    }

    // MARK: Sound

    private static let soundFolder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"
    private static let trashSound = NSSound(contentsOfFile: soundFolder + "/finder/move to trash.aif", byReference: true)
    private static let poofSound = NSSound(contentsOfFile: soundFolder + "/dock/poof item off dock.aif", byReference: true)

    private static func playSound(_ kind: Kind) {
        // Off when "Play user interface sound effects" is off.
        if let enabled = UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int, enabled == 0 { return }
        guard let sound = kind == .trash ? trashSound : poofSound else { return }
        sound.stop()
        sound.play()
    }

    // MARK: Puff of smoke

    /// Kept until their animation ends.
    private static var panels: [NSPanel] = []

    /// At the pointer, as when an icon is dragged off the Dock; in the middle of the window when
    /// the pointer is elsewhere (a delete from the keyboard).
    private static func showPoof() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        var center = NSEvent.mouseLocation
        if let window = NSApp.keyWindow, !window.frame.contains(center) {
            center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        }
        let size = PoofView.size
        let panel = NSPanel(contentRect: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PoofView())
        panel.orderFrontRegardless()
        panels.append(panel)
        Task {
            try? await Task.sleep(for: .milliseconds(Int(PoofView.duration * 1000) + 80))
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
    }
}

/// A small cloud that billows out and fades.
private struct PoofView: View {
    static let size: CGFloat = 76
    static let duration = 0.42

    /// Where each puff drifts to from the middle, and how big it is.
    private static let puffs: [(dx: CGFloat, dy: CGFloat, diameter: CGFloat)] = [
        (0, 0, 30), (-15, -7, 22), (15, -6, 22), (-9, 13, 20), (10, 12, 20), (0, -16, 18), (-19, 6, 15), (19, 5, 15),
    ]

    @State private var billowed = false
    @State private var faded = false

    var body: some View {
        ZStack {
            ForEach(Self.puffs.indices, id: \.self) { index in
                let puff = Self.puffs[index]
                Circle()
                    .fill(RadialGradient(colors: [Color.white, Color(white: 0.78)], center: .init(x: 0.4, y: 0.35),
                                         startRadius: 0, endRadius: puff.diameter / 2))
                    .frame(width: puff.diameter, height: puff.diameter)
                    .scaleEffect(billowed ? 1.3 : 0.3)
                    .offset(x: puff.dx * (billowed ? 1 : 0.15), y: puff.dy * (billowed ? 1 : 0.15))
            }
        }
        .opacity(faded ? 0 : 1)
        .shadow(color: .black.opacity(0.3), radius: 1.5)
        .frame(width: Self.size, height: Self.size)
        .onAppear {
            withAnimation(.easeOut(duration: Self.duration)) { billowed = true }
            // Fades late, so the cloud is seen before it goes.
            withAnimation(.easeIn(duration: Self.duration)) { faded = true }
        }
    }
}
