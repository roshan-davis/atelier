import AppKit
import AtelierCore

/// Until Nov 12, 2026 HDR was a separate app that left a request and a completion receipt in
/// the catalog's ProcessorJobs folder, which Atelier picked up while it was open. HDR is now a
/// mode of Atelier and registers its TIFF directly. At launch, any receipt the old app wrote
/// while Atelier was closed is still taken in once (validated in Core as before), so no saved
/// HDR result is lost. The folder is then renamed (kept, not deleted) so this runs only once.
@MainActor
enum LegacyHDRReceipts {
    static func importPending(into model: LibraryModel) {
        guard let directory = model.catalog.packageURL?.appendingPathComponent("ProcessorJobs", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.path) else { return }
        let catalog = model.catalog
        Task {
            let results = await Task.detached { () -> [Result<Int64?, Error>] in
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
                return files.filter { $0.pathExtension == "receipt" }.map { receiptURL in
                    Result {
                        let request = try ProcessorDocument.read(receiptURL.deletingPathExtension().appendingPathExtension("json"))
                        let receipt = try ProcessorReceipt.read(receiptURL)
                        if try catalog.hasConsumedProcessorResult(receipt, request: request) { return nil }
                        return try catalog.acceptProcessorResult(receipt, request: request)
                    }
                }
            }.value
            let done = directory.deletingLastPathComponent().appendingPathComponent("ProcessorJobs (old HDR app)", isDirectory: true)
            if !FileManager.default.fileExists(atPath: done.path) { try? FileManager.default.moveItem(at: directory, to: done) }
            var returned = 0
            for case .success(.some(let id)) in results {
                returned += 1
                if let url = try? catalog.fileURL(for: id) {
                    let settings = (try? catalog.developSettings(for: id)) ?? .neutral
                    model.previewScheduler.refresh(for: id, source: url, settings: settings)
                }
                model.develop.sourceChanged(id)
            }
            let failed = results.filter { if case .failure = $0 { return true } else { return false } }.count
            if returned > 0 {
                model.status = "Added \(returned) HDR TIFF\(returned == 1 ? "" : "s") saved by the old HDR app"
            } else if failed > 0 {
                model.status = "\(failed) HDR result\(failed == 1 ? "" : "s") from the old HDR app could not be added"
            }
        }
    }
}
