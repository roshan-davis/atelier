import AtelierCore
import AtelierHDRCore
import Foundation
import IOSurface

/// What HDR's previews need that depends only on the photo and Exposure: the tone mapper's
/// analysis and, when the GPU kernel is there, its uploaded copy. Shared by the ordinary render
/// and the live-frame queue, so each Exposure value is analyzed once. Only the 1600 px proxy's
/// is kept (about 27 MB, plus its upload); a full-size one would be ~400 MB.
final class HDRPreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var token = -1
    private var analysis: HDRToneMapper.Analysis?
    private var source: HDRPreviewRenderer.Source?

    /// Frees what was kept, for another photo or project.
    func reset() {
        lock.lock()
        token = -1; analysis = nil; source = nil
        lock.unlock()
    }

    /// `input`'s analysis at `exposure`, made now if needed. `token` names the photo shown;
    /// `keep` is false for the full-size image, whose analysis is used once.
    func analysis(_ input: HDRImage, exposure: Float, token: Int, keep: Bool) throws -> HDRToneMapper.Analysis {
        lock.lock()
        defer { lock.unlock() }
        return try analysisLocked(input, exposure: exposure, token: token, keep: keep)
    }

    /// The proxy uploaded for the GPU at `exposure`; nil when the kernel isn't available.
    func source(_ input: HDRImage, exposure: Float, token: Int) throws -> HDRPreviewRenderer.Source? {
        guard let renderer = HDRPreviewRenderer.shared else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if token == self.token, let source, source.matches(input, exposure: exposure) { return source }
        let analysis = try analysisLocked(input, exposure: exposure, token: token, keep: true)
        let made = renderer.source(input, analysis: analysis)
        if token >= self.token { source = made }
        return made
    }

    private func analysisLocked(_ input: HDRImage, exposure: Float, token: Int, keep: Bool) throws -> HDRToneMapper.Analysis {
        if token == self.token, let analysis, analysis.matches(input, exposure: exposure) { return analysis }
        let made = try HDRToneMapper.analyze(input, exposure: exposure)
        // A request for a photo already left (an older token) doesn't replace the newer one's.
        if keep, token >= self.token {
            if token != self.token || source.map({ !$0.matches(input, exposure: exposure) }) == true { source = nil }
            self.token = token; analysis = made
        }
        return made
    }
}

/// HDR's live slider frames, drawn on the GPU straight into the photo view's frame layer from a
/// queue of their own (`LiveFrameSink`), as Develop's are (`PhotoFeed`): no main thread, no
/// SwiftUI update and no read-back between a slider tick and the photo. Latest wins: while a
/// frame renders only the newest request waits.
final class HDRLiveFrames: @unchecked Sendable {
    struct Request {
        let input: HDRImage
        let settings: HDRSettings
        let token: Int
        let count: Int
        let epoch: Int
    }

    let cache: HDRPreviewCache
    let sink: LiveFrameSink
    private let surfaces = DisplaySurfaces(colorSpace: HDRPreviewRenderer.sRGB)
    private let queue = DispatchQueue(label: "Atelier HDR live frames", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: Request?
    private var running = false
    /// Called on the main thread when a frame couldn't be shown (no free surface, another
    /// shape, a failed render), so the ordinary render draws it instead.
    private let onMiss: @MainActor () -> Void

    init(cache: HDRPreviewCache, sink: LiveFrameSink, onMiss: @escaping @MainActor () -> Void) {
        self.cache = cache; self.sink = sink; self.onMiss = onMiss
    }

    func submit(_ request: Request) {
        lock.lock()
        pending = request
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            if !draw(request) {
                let onMiss = self.onMiss
                DispatchQueue.main.async { MainActor.assumeIsolated { onMiss() } }
            }
        }
    }

    /// Whether the frame was shown or was rightly dropped as stale.
    private func draw(_ request: Request) -> Bool {
        guard let renderer = HDRPreviewRenderer.shared,
              let source = try? cache.source(request.input, exposure: request.settings.exposure, token: request.token),
              let image = renderer.image(source, settings: request.settings),
              let surface = surfaces.checkOut(width: source.width, height: source.height) else { return false }
        guard renderer.render(image, to: surface, flipped: DevelopRenderer.surfaceNeedsFlip) else {
            surfaces.checkIn(surface)
            return false
        }
        switch sink.present(surface, count: request.count, epoch: request.epoch, pool: surfaces) {
        case .shown, .stale: return true
        case .wrongShape, .noView: return false
        }
    }
}
