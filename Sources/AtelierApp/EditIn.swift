import AppKit
import AtelierCore
import Foundation
import UniformTypeIdentifiers

/// An app photos can be sent to with Photo > Edit In, and how the copy it gets is rendered.
struct ExternalEditor: Codable, Hashable, Identifiable {
    enum FileFormat: String, Codable, CaseIterable {
        case tiff, jpeg

        var label: String { self == .tiff ? "TIFF (16-bit)" : "JPEG" }
        var exportFormat: ExportFormat { self == .tiff ? .tiff : .jpeg }
    }

    var id: String { appPath }
    var name: String
    var appPath: String
    var format: FileFormat = .tiff
    var colorSpace: ExportColorSpace = .proPhoto
    /// Bake the photo's develop settings into the copy (Lightroom's "Edit a Copy with
    /// Lightroom Adjustments"); off sends the original pixels.
    var applyDevelop = true

    var appURL: URL { URL(fileURLWithPath: appPath) }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: appPath) }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: appPath) }

    init(name: String, appURL: URL) {
        self.name = name
        self.appPath = appURL.path
    }

    init(appURL: URL) {
        let name = FileManager.default.displayName(atPath: appURL.path)
        self.init(name: (name as NSString).deletingPathExtension, appURL: appURL)
    }
}

/// The Edit In list, kept in user defaults. Until the list is edited it is whatever known
/// photo editors are installed.
enum ExternalEditorStore {
    static let defaultsKey = "editIn.editors"

    /// Well-known photo editors, by bundle identifier.
    private static let known: [(name: String, bundleIDs: [String])] = [
        ("Adobe Photoshop", ["com.adobe.Photoshop"]),
        ("Affinity Photo", ["com.seriflabs.affinityphoto2", "com.seriflabs.affinityphoto", "com.canva.affinity"]),
        ("Pixelmator Pro", ["com.pixelmatorteam.pixelmator.x"]),
        ("Photomator", ["com.pixelmatorteam.photomator"]),
        ("GIMP", ["org.gimp.gimp-3.0", "org.gimp.gimp-2.10", "org.gimp.gimp"]),
        ("Krita", ["org.krita"]),
    ]

    static func load() -> [ExternalEditor] {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let editors = try? JSONDecoder().decode([ExternalEditor].self, from: data) {
            return editors
        }
        return detected()
    }

    static func save(_ editors: [ExternalEditor]) {
        if let data = try? JSONEncoder().encode(editors) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// The known editors installed on this Mac.
    static func detected() -> [ExternalEditor] {
        known.compactMap { entry in
            for bundleID in entry.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    return ExternalEditor(name: entry.name, appURL: url)
                }
            }
            return nil
        }
    }
}

/// Watches the folders holding files open in external editors. Editors usually save by
/// writing a temporary file and renaming it, so the folder is watched rather than the file,
/// and a change is recognized by the file's modification date.
@MainActor
final class EditWatcher {
    private struct Watched {
        var url: URL
        var modified: Date?
    }

    private var files: [Int64: Watched] = [:]
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingCheck: DispatchWorkItem?
    /// Called on the main actor with the photo whose file changed.
    var onChange: ((Int64) -> Void)?

    /// `known` is the modification date the catalog has; a newer file is reported at once.
    func watch(_ assetID: Int64, at url: URL, known: Date? = nil) {
        if let known {
            guard files[assetID] == nil else { return }
            files[assetID] = Watched(url: url, modified: known)
            if let modified = Self.modified(url), abs(modified.timeIntervalSince(known)) > 1 {
                files[assetID]?.modified = modified
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onChange?(assetID) } }
            }
        } else {
            files[assetID] = Watched(url: url, modified: Self.modified(url))
        }
        let folder = url.deletingLastPathComponent().path
        guard sources[folder] == nil else { return }
        let descriptor = open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources[folder] = source
    }

    /// Saves come in bursts; look once things settle.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func check() {
        for (id, watched) in files {
            let modified = Self.modified(watched.url)
            guard let modified, modified != watched.modified else { continue }
            files[id]?.modified = modified
            onChange?(id)
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

extension LibraryModel {
    var externalEditors: [ExternalEditor] { ExternalEditorStore.load().filter(\.isInstalled) }

    /// Photo > Edit In: renders a copy next to the original (TIFF or JPEG, with or without the
    /// develop settings), catalogs it stacked on the original, opens it in the editor, and
    /// picks up every save. A photo that already is an edit opens as it is.
    func editIn(_ editor: ExternalEditor) {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        let catalog = self.catalog
        let host = ProcessorHost(catalog: catalog, importer: Importer(catalog: catalog, previews: nil, scheduler: previewScheduler),
                                 originals: originals)
        status = ids.count == 1 ? "Preparing the photo for \(editor.name)…" : "Preparing \(ids.count) photos for \(editor.name)…"
        Task.detached {
            var opened: [(Int64, URL)] = []
            var failures: [Problem] = []
            var changed: [OriginalChangedError] = []
            for id in ids {
                do {
                    if let derivation = try catalog.derivation(of: id), derivation.kind == .externalEdit,
                       let url = try catalog.fileURL(for: id) {
                        opened.append((id, url))
                        continue
                    }
                    let original = try host.original(of: id)
                    var settings = ExportSettings(destination: DerivedFiles.folder(for: original))
                    settings.format = editor.format.exportFormat
                    settings.quality = 0.95
                    settings.colorSpace = editor.colorSpace
                    settings.metadata = .all
                    let base = original.deletingPathExtension().lastPathComponent + "-Edit"
                    let file = try host.renderInput(of: id, settings: settings, baseName: base, develop: editor.applyDevelop)
                    let edit = try host.registerResult(file, on: id, kind: .externalEdit, name: editor.name)
                    opened.append((edit.assetID, file))
                } catch let change as OriginalChangedError {
                    changed.append(change)
                } catch {
                    let name = (try? catalog.detail(for: id))?.asset.filename ?? "Photo"
                    failures.append(Problem(name: name, reason: error.localizedDescription))
                }
            }
            let stopped = changed
            await MainActor.run {
                self.showProcessorResults(opened.map { ProcessorResult(assetID: $0.0, url: $0.1) })
                for (id, url) in opened { self.editWatcher.watch(id, at: url) }
                // Snapshot runs need the derivative and stack, while Preview owns its own windows.
                if LayoutSnapshots.outputFolder == nil {
                    let configuration = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open(opened.map(\.1), withApplicationAt: editor.appURL,
                                            configuration: configuration) { _, error in
                        guard let error else { return }
                        Task { @MainActor in self.status = "\(editor.name) could not open the file: \(error.localizedDescription)" }
                    }
                }
                self.status = opened.isEmpty ? "Nothing was sent to \(editor.name)"
                    : "Opened \(opened.count) photo\(opened.count == 1 ? "" : "s") in \(editor.name). Saves show up here."
                if !failures.isEmpty {
                    self.problems = failures
                    self.problemsTitle = "These photos could not be sent to \(editor.name)"
                }
                self.reviewChangedOriginals(stopped, command: "Edit In \(editor.name)") { ids in
                    self.withTargets(ids) { self.editIn(editor) }
                }
            }
        }
    }

    /// An external editor saved: re-read the file and rebuild its previews.
    func editedFileChanged(_ id: Int64) {
        try? catalog.refreshFileInfo(for: id)
        previewScheduler.retryFailed(for: id)
        let settings = (try? catalog.developSettings(for: id)) ?? .neutral
        develop.refreshPreviews(for: id, settings: settings)
        develop.sourceChanged(id)
        if focusedID == id { reloadDetail() }
    }

    /// Edit In > Other Application…: pick any app, which then joins the list.
    func editInOtherApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App to Edit In"
        panel.prompt = "Edit In"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var editors = ExternalEditorStore.load()
        let editor = editors.first { $0.appPath == url.path } ?? ExternalEditor(appURL: url)
        if !editors.contains(where: { $0.appPath == url.path }) {
            editors.append(editor)
            ExternalEditorStore.save(editors)
        }
        editIn(editor)
    }
}

extension LibraryModel {
    /// What every Processor's results do once catalogued (Edit In, AI recipes): build their
    /// previews first, and select them, the first in focus.
    func showProcessorResults(_ results: [ProcessorResult]) {
        for result in results {
            previewScheduler.request(.thumbnail, for: result.assetID, source: result.url, urgent: true)
            previewScheduler.request(.preview, for: result.assetID, source: result.url)
        }
        guard let first = results.first else { return }
        selection = Set(results.map(\.assetID))
        focusedID = first.assetID
    }
}
