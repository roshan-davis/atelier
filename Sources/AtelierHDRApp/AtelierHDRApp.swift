import AppKit
import SwiftUI
import AtelierHDRCore

@main
struct AtelierHDRApp: App {
    @NSApplicationDelegateAdaptor(HDRAppDelegate.self) private var delegate
    @StateObject private var editor = HDRController()
    var body: some Scene {
        WindowGroup("Atelier HDR") {
            HDRWorkspace(editor: editor)
                .frame(minWidth: 1100, minHeight: 680)
                .environment(\.theme, Theme.current)
                .task {
                    delegate.editor = editor; editor.launch()
                    #if DEBUG
                    if let path = ProcessInfo.processInfo.environment["ATELIER_HDR_SNAPSHOTS"]
                        ?? Bundle.main.object(forInfoDictionaryKey: "AtelierHDRSnapshotPath") as? String {
                        await LayoutSnapshots.run(editor: editor, into: URL(fileURLWithPath: path))
                    }
                    #endif
                }
                .onOpenURL { editor.openURL($0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open HDR Project…") { editor.chooseOpen() }.keyboardShortcut("o")
                Divider()
                Button("Save") { editor.save() }.keyboardShortcut("s").disabled(editor.before == nil || editor.busy)
                Button("Save As New…") { editor.save(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(editor.before == nil || editor.busy)
            }
            CommandGroup(replacing: .help) {
                Button("Atelier HDR Help") { HelpWindow.shared.show(page: "hdr") }.keyboardShortcut("?", modifiers: [.command])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo HDR Adjustment") { editor.undo() }.keyboardShortcut("z").disabled(!editor.canUndo || editor.busy)
                Button("Redo HDR Adjustment") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo || editor.busy)
            }
        }
    }
}

@MainActor final class HDRAppDelegate: NSObject, NSApplicationDelegate {
    weak var editor: HDRController?
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); Theme.current.apply(); NSApp.activate(ignoringOtherApps: true)
        PanelHelp.hasTopic = { HelpWindow.topic(forPanel: $0) != nil }
        PanelHelp.show = { title in
            if let topic = HelpWindow.topic(forPanel: title) { HelpWindow.shared.show(page: topic.page, section: topic.section) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let editor = self?.editor, !(NSApp.keyWindow?.firstResponder is NSTextView),
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
                switch KeyBindings.action(for: key) {
                case .zoom:
                    editor.zoom.level = editor.zoom.report.isZoomedPastFit ? .fit : .percent(ZoomLevel.clickZoomPercent)
                    return nil
                case .beforeAfter: editor.originalToggled.toggle(); return nil
                case .compareMode: editor.compareKeySignal += 1; return nil
                default: return event
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let window = note.object as? NSWindow, window.title == "Atelier HDR" { window.delegate = self } }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmClose() ? .terminateNow : .terminateCancel
    }
    private func confirmClose() -> Bool {
        guard let editor else { return true }
        if editor.busy { editor.cancel(); return false }
        guard editor.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Close without saving HDR changes?"
        alert.informativeText = "The last saved project and TIFF will be kept."
        alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Close Without Saving")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
extension HDRAppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }
}

struct HDRWorkspace: View {
    @ObservedObject var editor: HDRController
    @State var compare = "Split"
    @State private var split: CGFloat = 0.5
    @State private var toneExpanded = true
    @State private var artifactsExpanded = true
    @State private var solo = false
    @Environment(\.theme) private var theme
    @ObservedObject private var keys = ModifierKeys.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "camera.filters").foregroundStyle(Color.accentColor)
                Text("Atelier HDR").font(.headline)
                Text("From Atelier · \(editor.sourceName)").foregroundStyle(.secondary).lineLimit(1)
                if editor.dirty { Text("Edited").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if editor.busy { ProgressView().controlSize(.small); Button("Cancel", action: editor.cancel).keyboardShortcut(.cancelAction) }
                Button("Save & Return to Atelier") { editor.save(returnToAtelier: true) }
                    .buttonStyle(.borderedProminent).disabled(editor.before == nil || editor.busy)
            }.padding(12).background(Color(nsColor: theme.chrome))
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SOURCE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Label(editor.sourceName, systemImage: "photo").lineLimit(2)
                    Text("Single-image HDR · Original").font(.callout.weight(.semibold))
                    Text("Tone-map the original’s available range and adjust texture. Virtual exposures add no captured detail.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Finish color grading in Atelier Develop after return.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Project…", action: editor.chooseOpen).disabled(editor.busy)
                    Button("Relink Source…", action: editor.relinkSource).disabled(editor.busy)
                }.padding(14).frame(width: 200).frame(maxHeight: .infinity).background(Color(nsColor: theme.panel))
                Divider()
                VStack(spacing: 0) {
                    canvas
                    Divider()
                    HStack {
                        Picker("Compare", selection: $compare) {
                            Text("Off").tag("Off"); Text("Side by Side").tag("Side by Side"); Text("Split").tag("Split")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        Text("⌥ Original").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        ZoomControls(zoom: editor.zoom, compact: true)
                    }.padding(8).background(Color(nsColor: theme.chrome))
                }
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        PanelSection(title: "Tone Mapping", isExpanded: $toneExpanded, soloMode: $solo,
                                     isModified: editor.dirty, reset: { editor.reset([\.exposure, \.compression, \.microcontrast, \.detail]) },
                                     isOn: editor.switchBinding(\.toneEnabled),
                                     expandAll: expand, collapseAll: collapse) {
                            VStack(alignment: .leading, spacing: 10) {
                                row("Exposure", \.exposure, -5...5, step: 0.05)
                                row("Range", \.compression, 0...1, step: 0.01)
                                GroupHeading(title: "Texture", reset: { editor.reset([\.microcontrast, \.detail]) })
                                row("Microcontrast", \.microcontrast, -1...1, step: 0.01)
                                row("Detail", \.detail, -1...1, step: 0.01)
                            }
                        }
                        PanelSection(title: "Artifacts", isExpanded: $artifactsExpanded, soloMode: $solo,
                                     reset: { editor.reset([\.shadowProtection, \.highlightProtection]) },
                                     isOn: editor.switchBinding(\.artifactsEnabled),
                                     expandAll: expand, collapseAll: collapse) {
                            VStack(alignment: .leading, spacing: 10) {
                                row("Shadows", \.shadowProtection, 0...1, step: 0.01)
                                row("Highlights", \.highlightProtection, 0...1, step: 0.01)
                                Text("Limits texture enhancement near black and bright highlights.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack { Spacer(); Button("Reset All", action: editor.reset); Spacer() }.padding()
                    }.disabled(editor.before == nil || editor.busy)
                }.frame(width: 300).background(Color(nsColor: theme.panel))
            }
            Divider()
            HStack { Text(editor.status).lineLimit(1); Spacer(); Text("16-bit TIFF + HDR project").foregroundStyle(.secondary) }
                .font(.caption).padding(8).background(Color(nsColor: theme.chrome))
        }
        .onChange(of: editor.compareKeySignal) { _, _ in
            compare = compare == "Off" ? "Side by Side" : compare == "Side by Side" ? "Split" : "Off"
        }
        .onChange(of: toneExpanded) { _, expanded in if expanded && solo { artifactsExpanded = false } }
        .onChange(of: artifactsExpanded) { _, expanded in if expanded && solo { toneExpanded = false } }
        .onReceive(editor.zoom.$level) { _ in Task { @MainActor in editor.zoomChanged() } }
        .alert("HDR needs attention", isPresented: Binding(get: { editor.error != nil }, set: { if !$0 { editor.error = nil } })) {
            Button("OK") { editor.error = nil }
        } message: { Text(editor.error ?? "") }
    }
    private func expand() { toneExpanded = true; artifactsExpanded = true }
    private func collapse() { toneExpanded = false; artifactsExpanded = false }
    private func row(_ title: String, _ key: WritableKeyPath<HDRSettings, Float>, _ range: ClosedRange<Double>, step: Double) -> some View {
        SliderRow(label: title, value: editor.binding(key, name: title), range: range, step: step,
                  origin: Double(HDRSettings()[keyPath: key]), format: { String(format: "%.2f", $0) }, labelWidth: 94,
                  onOption: nil, onEditingChanged: editor.gesture)
    }
    private func photo(_ image: NSImage?, visible: CGFloat? = nil) -> some View {
        ZoomableImageView(image: image, pixelSize: editor.pixelSize, zoom: editor.zoom,
                          visibleWidth: visible, onReport: { editor.zoom.report = $0 }, menu: { nil })
    }
    @ViewBuilder private var canvas: some View {
        if editor.before == nil {
            ContentUnavailableView("Open an HDR Project", systemImage: "camera.filters",
                                   description: Text("Start in Atelier > Photo > Edit In > HDR App."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if keys.option || editor.originalToggled {
            photo(editor.before)
        } else if compare == "Side by Side" {
            HStack(spacing: 1) { photo(editor.before); photo(editor.after) }
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    photo(editor.after)
                    if compare == "Split" {
                        photo(editor.before, visible: split)
                        Rectangle().fill(.white).frame(width: 2).offset(x: geometry.size.width * split)
                            .allowsHitTesting(false)
                        Image(systemName: "arrow.left.and.right.circle.fill")
                            .font(.title2).foregroundStyle(.white).shadow(radius: 2)
                            .frame(width: 30, height: 46).contentShape(Rectangle())
                            .offset(x: geometry.size.width * split - 15)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("hdrCanvas")).onChanged { drag in
                                split = max(0.03, min(0.97, drag.location.x / geometry.size.width))
                            }).cursor(.columnResize)
                    }
                }
            }.coordinateSpace(name: "hdrCanvas")
        }
    }
}
