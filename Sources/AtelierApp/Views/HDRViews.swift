import AppKit
import AtelierCore
import AtelierHDRCore
import SwiftUI

/// The photo in HDR mode, with Develop's Before and After views and zoom bar. It shares the
/// window's zoom (`LibraryModel.zoomState`), so zoom and the spot in view carry over from and
/// back to Loupe and Develop.
struct HDRImageView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.theme) private var theme
    @ObservedObject var hdr: HDRController
    /// With the Filmstrip showing, ⌃Tab's "photos" outline goes on the Filmstrip instead.
    @AppStorage(Filmstrip.visibleKey) private var filmstripVisible = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: theme.surround)
                if let before = hdr.before {
                    let after = hdr.after ?? before
                    if hdr.showingBefore || hdr.compareMode == .off {
                        // Live slider frames are drawn into the After photo (`PhotoFeed`), as in Develop.
                        photo(hdr.showingBefore ? before : after, feed: hdr.showingBefore ? nil : hdr.photoFeed)
                    } else if hdr.compareMode == .sideBySide {
                        HStack(spacing: 12) {
                            ComparePane(image: before, label: "Before", pixelSize: hdr.pixelSize, zoom: model.zoomState,
                                        onReport: onZoomReport, menu: { model.photoMenu(includeZoom: true) })
                            ComparePane(image: after, label: "After", pixelSize: hdr.pixelSize, zoom: model.zoomState,
                                        onReport: onZoomReport, menu: { model.photoMenu(includeZoom: true) },
                                        feed: hdr.photoFeed)
                        }
                        .padding(.horizontal, 8)
                    } else {
                        SliderCompareView(before: before, after: after, pixelSize: hdr.pixelSize, zoom: model.zoomState,
                                          onReport: onZoomReport, menu: { model.photoMenu(includeZoom: true) },
                                          position: $hdr.sliderPosition, feed: hdr.photoFeed)
                    }
                    if hdr.showingBefore { Badge(text: "Before").padding(14) }
                } else if hdr.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hdr.needsRelink {
                    ContentUnavailableView {
                        Label("The HDR Project's Source Is Missing", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Its private copy of the original is missing or changed. Choose an identical copy of the original to use again.")
                    } actions: {
                        Button("Relink Source…", action: hdr.relinkSource)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.focusedID == nil {
                    ContentUnavailableView("Select a Photo", systemImage: "camera.filters",
                                           description: Text("HDR tone-maps one photo's original. Choose it in the Filmstrip."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .areaFocusFlash(.photo, enabled: !filmstripVisible)
            Divider()
            AdaptiveControlBar(sizingKey: HDRBarKey(slider: hdr.compareMode == .slider, busy: hdr.busy)) {
                bottomBar(showHint: true, compactZoom: false)
            } compact: {
                bottomBar(showHint: false, compactZoom: false)
            } minimum: {
                bottomBar(showHint: false, compactZoom: true)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onAppear { hdr.open(model.focusedID) }
        // After the zoom change is published: at 100% and closer the full-size original loads.
        .onReceive(model.zoomState.$level) { _ in Task { @MainActor in hdr.zoomChanged() } }
        .alert("HDR needs attention", isPresented: Binding(get: { hdr.error != nil }, set: { if !$0 { hdr.error = nil } })) {
            Button("OK") { hdr.error = nil }
        } message: { Text(hdr.error ?? "") }
    }

    private struct HDRBarKey: Hashable {
        var slider: Bool
        var busy: Bool
    }

    private func photo(_ image: NSImage, feed: PhotoFeed?) -> some View {
        ZoomableImageView(image: image, pixelSize: hdr.pixelSize, zoom: model.zoomState,
                          onReport: onZoomReport, menu: { model.photoMenu(includeZoom: true) }, feed: feed)
    }

    private func onZoomReport(_ report: ZoomReport) {
        if model.zoomReport != report { model.zoomReport = report }
    }

    private func bottomBar(showHint: Bool, compactZoom: Bool) -> some View {
        HStack(spacing: 10) {
            comparePicker.disabled(!hdr.hasPhoto)
            if hdr.busy {
                ProgressView().controlSize(.small)
                if showHint { Text("Saving the full-size TIFF…").foregroundStyle(.secondary).fixedSize() }
                Button("Cancel", action: hdr.cancel).help("Stop the save; the last saved TIFF is kept (Esc)")
            } else if showHint, hdr.compareMode == .slider {
                Text("Drag the divider to compare").foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 8)
            ZoomControls(zoom: model.zoomState, compact: compactZoom)
        }
    }

    /// The same Before and After icons as Develop's.
    private var comparePicker: some View {
        let key = KeyBindings.display(KeyBindings.key(for: .compareMode))
        return IconSegmentedControl(segments: CompareMode.allCases.map { mode in
            IconSegmentedControl<CompareMode>.Segment(value: mode, symbol: mode.symbol, text: mode.label,
                                                      help: "Before and After: \(mode.label) (\(key) cycles)")
        }, selection: $hdr.compareMode)
        .fixedSize()
    }
}

/// The right panel in HDR mode: Tone Mapping, with the same panel header, switch and sliders as
/// Develop, and Reset All and Save at the foot, as in Lightroom. Texture protection near black
/// and in bright highlights is built in (the old Artifacts sliders, which Rosh found had no
/// visible effect, Nov 12, 2026); Highlights and Shadows work like Develop's.
struct HDRPanel: View {
    @ObservedObject var hdr: HDRController
    @AppStorage("hdr.expandedPanels") private var expandedList = "tone"
    @AppStorage("hdr.soloMode") private var soloMode = false
    private static let panels = ["tone"]

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedList.split(separator: ",").contains(Substring(id)) }, set: { open in
            var set = Set(expandedList.split(separator: ",").map(String.init))
            if open {
                if soloMode { set = [] }
                set.insert(id)
            } else {
                set.remove(id)
            }
            expandedList = set.sorted().joined(separator: ",")
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    PanelSection(title: "Tone Mapping", isExpanded: isExpanded("tone"), soloMode: $soloMode,
                                 isModified: hdr.isModified(HDRController.toneKeys),
                                 reset: { hdr.reset(HDRController.toneKeys) },
                                 isOn: hdr.switchBinding(\.toneEnabled),
                                 expandAll: expandAll, collapseAll: collapseAll) {
                        VStack(alignment: .leading, spacing: 10) {
                            row("Exposure", \.exposure, -5...5, step: 0.05)
                            row("Range", \.compression, 0...1, step: 0.01)
                            GroupHeading(title: "Tone", reset: { hdr.reset(HDRController.regionKeys) })
                            row("Highlights", \.highlights, -1...1, step: 0.01)
                            row("Shadows", \.shadows, -1...1, step: 0.01)
                            GroupHeading(title: "Texture", reset: { hdr.reset(HDRController.textureKeys) })
                            row("Microcontrast", \.microcontrast, -1...1, step: 0.01)
                            row("Detail", \.detail, -1...1, step: 0.01)
                        }
                    }
                }
            }
            .disabled(!hdr.hasPhoto || hdr.busy)
            Divider()
            HStack {
                Button("Reset All", action: hdr.reset)
                    .disabled(!hdr.hasPhoto || hdr.busy)
                    .help("Put every HDR slider back to its default (one undo step)")
                Spacer()
                // A visible way out besides Esc (Rosh, Nov 12, 2026), like Lightroom's Done in its tools.
                Button("Done", action: hdr.done)
                    .disabled(hdr.busy)
                    .help("Close HDR and go back to the view you came from (Esc). Unsaved changes are asked about first.")
                Button(hdr.revision > 0 ? "Save" : "Save HDR") { hdr.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hdr.hasPhoto || hdr.busy || (!hdr.dirty && hdr.revision > 0))
                    .help(hdr.revision > 0 ? "Update the HDR TIFF with these settings (⌘S)"
                                           : "Make the HDR TIFF, stacked with the original (⌘S)")
            }
            .padding(10)
        }
    }

    private func expandAll() { expandedList = Self.panels.joined(separator: ",") }
    private func collapseAll() { expandedList = "" }

    private func row(_ title: String, _ key: WritableKeyPath<HDRSettings, Float>, _ range: ClosedRange<Double>,
                     step: Double) -> some View {
        SliderRow(label: title, value: hdr.binding(key), range: range, step: step,
                  origin: Double(HDRSettings()[keyPath: key]), format: { String(format: "%.2f", $0) }, labelWidth: 94,
                  onEditingChanged: hdr.gesture)
    }
}

/// The left column in HDR mode: what is being tone-mapped and where its result goes.
struct HDRSidebar: View {
    @ObservedObject var hdr: HDRController
    @AppStorage("hdr.sidebarCollapsed") private var collapsedList = ""

    private func isExpanded(_ section: String) -> Binding<Bool> {
        Binding(get: { !collapsedList.split(separator: ",").contains(Substring(section)) }, set: { open in
            var collapsed = Set(collapsedList.split(separator: ",").map(String.init))
            if open { collapsed.remove(section) } else { collapsed.insert(section) }
            collapsedList = collapsed.sorted().joined(separator: ",")
        })
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                SidebarSection(title: "Source", isExpanded: isExpanded("source")) {
                    EmptyView()
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(hdr.sourceName.isEmpty ? "No photo" : hdr.sourceName, systemImage: "photo")
                            .lineLimit(2)
                        Text("Single-image HDR from the original's pixels. Develop edits aren't included; finish the color in Develop after saving.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SidebarSection(title: "HDR Result", isExpanded: isExpanded("result")) {
                    EmptyView()
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        if hdr.revision > 0 || hdr.resultAssetID != nil {
                            Label(resultName, systemImage: "doc.richtext").lineLimit(2)
                            Text(hdr.dirty ? "Edited since the last save." : "Saved.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Not saved yet. Save makes a 16-bit TIFF next to the original, stacked with it, and an HDR project that reopens these sliders.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button("Save As New…") { hdr.save(asNew: true) }
                                .disabled(!hdr.hasPhoto || hdr.busy)
                                .help("Make a separate HDR TIFF and project; the earlier one is kept (⇧⌘S)")
                            if hdr.needsRelink {
                                Button("Relink Source…", action: hdr.relinkSource)
                            }
                        }
                    }
                }
            }
        }
    }

    private var resultName: String {
        hdr.projectURL?.deletingPathExtension().appendingPathExtension("tif").lastPathComponent ?? "HDR TIFF"
    }
}
