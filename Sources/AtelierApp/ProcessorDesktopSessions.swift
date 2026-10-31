import AppKit
import AtelierCore
import AtelierHDRCore

/// The native interactive Processor adapter. Requests persist inside the owning catalog;
/// receipts are validated in Core before one transactional registration. Ordinary Edit In
/// remains the file-editor adapter; this adds project/result identity at the same boundary.
@MainActor
final class ProcessorDesktopSessions {
    private weak var model: LibraryModel?
    private var timer: Timer?
    private var checking = false
    private var seen: [String: Date] = [:]
    private var processes: [Process] = []
    init(model: LibraryModel) { self.model = model }
    deinit { timer?.invalidate() }

    private var directory: URL? { model?.catalog.packageURL?.appendingPathComponent("ProcessorJobs", isDirectory: true) }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        check()
    }
    func openHDR() {
        guard let model, model.targetIDs.count == 1, let sourceID = model.targetIDs.first,
              let directory else { return }
        guard let executable = Self.hdrExecutable else {
            model.status = "Build AtelierHDRApp once in Xcode, or run swift build in this checkout, then try HDR App again."
            return
        }
        let catalog = model.catalog
        model.status = "Preparing HDR session…"
        Task {
            do {
                var request = try await Task.detached { () -> ProcessorDocument in
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if let association = try catalog.processorAssociation(for: sourceID) {
                        let manifest = try HDRProjectStore.metadata(at: association.projectURL)
                        guard manifest.projectID == association.projectID, manifest.outputID == association.outputID else {
                            throw ProcessorDocumentError.invalidRequest
                        }
                        let ownedSource = association.projectURL.appendingPathComponent("Sources").appendingPathComponent(manifest.sourceName)
                        return ProcessorDocument(sourceAssetID: association.sourceAssetID, sourceURL: try catalog.fileURL(for: association.sourceAssetID) ?? ownedSource,
                            sourceHash: association.sourceHash, projectURL: association.projectURL,
                            expectedProjectID: association.projectID, outputID: association.outputID)
                    }
                    guard let source = try catalog.fileURL(for: sourceID) else {
                        throw ExportError("The original is offline. Reconnect its drive before opening HDR.")
                    }
                    let stem = source.deletingPathExtension().lastPathComponent + "-HDR-" + UUID().uuidString.prefix(8)
                    let projectURL = DerivedFiles.folder(for: source).appendingPathComponent(stem).appendingPathExtension("atelierhdr")
                    return ProcessorDocument(sourceAssetID: sourceID, sourceURL: source,
                        sourceHash: try FileHasher.sha256(of: source), projectURL: projectURL)
                }.value
                request.uiPreferences = Dictionary(uniqueKeysWithValues: ["appearance.theme", "zoom.clickPercent", "keys.zoom", "keys.beforeAfter", "keys.compareMode"].compactMap { key in
                    UserDefaults.standard.object(forKey: key).map { (key, String(describing: $0)) }
                })
                let documentURL = directory.appendingPathComponent(request.jobID.uuidString + ".json")
                try request.write(to: documentURL)
                if executable.pathExtension == "app" {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.arguments = ["--processor-document", documentURL.path]
                    configuration.createsNewApplicationInstance = true
                    try await NSWorkspace.shared.openApplication(at: executable, configuration: configuration)
                } else {
                    let process = Process(); process.executableURL = executable
                    process.arguments = ["--processor-document", documentURL.path]
                    process.terminationHandler = { process in
                        guard process.terminationStatus != 0 else { return }
                        Task { @MainActor [weak model] in model?.status = "The HDR companion stopped before completing. Your saved project is preserved." }
                    }
                    try process.run(); processes.removeAll { !$0.isRunning }; processes.append(process)
                }
                model.status = "Opened Lightfast HDR. Save returns a TIFF stacked with the source."
                start()
            } catch { model.status = "HDR could not open: \(error.localizedDescription)" }
        }
    }
    private static var hdrExecutable: URL? {
        let packaged = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Lightfast HDR.app")
        if FileManager.default.fileExists(atPath: packaged.path) { return packaged }
        #if DEBUG
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let developmentHelper = checkout.appendingPathComponent(".build/debug/AtelierHDRApp")
        if FileManager.default.isExecutableFile(atPath: developmentHelper.path) { return developmentHelper }
        #endif
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("AtelierHDRApp")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AtelierHDRApp")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }
    private func check() {
        guard !checking, let directory, let model else { return }
        checking = true
        let prior = seen, catalog = model.catalog
        Task {
            let results = await Task.detached { () -> [(String, Date, Result<Int64?, Error>)] in
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
                return files.filter { $0.pathExtension == "receipt" }.compactMap { receiptURL in
                    guard let date = try? receiptURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          prior[receiptURL.path] != date else { return nil }
                    do {
                        let request = try ProcessorDocument.read(receiptURL.deletingPathExtension().appendingPathExtension("json"))
                        let receipt = try ProcessorReceipt.read(receiptURL)
                        if try catalog.hasConsumedProcessorResult(receipt, request: request) { return (receiptURL.path, date, .success(nil)) }
                        return (receiptURL.path, date, .success(try catalog.acceptProcessorResult(receipt, request: request)))
                    } catch { return (receiptURL.path, date, .failure(error)) }
                }
            }.value
            for (path, date, result) in results {
                seen[path] = date
                switch result {
                case .success(nil): break
                case .success(.some(let id)):
                    if let url = try? catalog.fileURL(for: id) {
                        let settings = (try? catalog.developSettings(for: id)) ?? .neutral
                        model.previewScheduler.refresh(for: id, source: url, settings: settings)
                    }
                    model.selection = [id]; model.focusedID = id; model.openDevelop()
                    if model.develop.assetID == id { model.develop.reopen() }
                    model.status = "HDR saved and returned. Finish color grading in Develop."
                case .failure(let error): model.status = "HDR return needs attention: \(error.localizedDescription)"
                }
            }
            checking = false
        }
    }
}

extension LibraryModel {
    func editInHDR() { processorSessions.openHDR() }
}
