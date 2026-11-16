import Foundation
import OnnxRuntimeBindings

/// What every ONNX Runtime model in Atelier shares (Fine Edges, Depth, AI Denoise): one
/// environment, session and run options that give memory back, and unloading a model it hasn't
/// used for a while (AT-077, review items R1 and M1).
///
/// ONNX Runtime's CPU code keeps the working memory of a run in an arena and, by default, never
/// gives it back while the session lives. Mac check of PR #157 (Nov 16, 2026, Z f NEF, 48 GB
/// Mac): Select Subject with Fine Edges (Fast) added about 8 GB, and it stayed until the model
/// was unloaded (10.0 GB to 1.4 GB). Now each run shrinks the arena when it ends
/// (`runOptions`), weights are allocated outside the arena (`tune`), and a model idle for
/// `idleSeconds` is unloaded (`IdleUnload`); macOS's memory warnings and closing a photo or
/// Lens Blur unload them at once (`RenderMemory.releaseAll`).
public enum OnnxHost {
    /// How long a model stays loaded after its last run. Loading again takes about half a second
    /// (Depth, Fast) to a few seconds (Hair Detail), and a matte or depth map once found is kept
    /// by its own cache, so most edits never run the model again.
    public static let idleSeconds: TimeInterval = 30

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: ORTEnv?

    /// The one ONNX Runtime environment (it holds the thread pools and logging).
    static func environment() throws -> ORTEnv {
        try lock.withLock {
            if let shared { return shared }
            let made = try ORTEnv(loggingLevel: .warning)
            shared = made
            return made
        }
    }

    /// Session options every model starts from: weights allocated with malloc rather than in
    /// the arena, so the arena holds only a run's working memory and can shrink to nothing.
    static func tune(_ options: ORTSessionOptions) throws {
        try options.addConfigEntry(withKey: "session.use_device_allocator_for_initializers", value: "1")
    }

    /// Run options that shrink the CPU arena when the run ends, giving its working memory back.
    static func runOptions() throws -> ORTRunOptions {
        let options = try ORTRunOptions()
        try options.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
        return options
    }

    /// Unloads one model after it has been idle for `OnnxHost.idleSeconds`: call `touch()` after
    /// each run; `unload` runs on a background queue.
    final class IdleUnload: @unchecked Sendable {
        private let name: String
        private let unload: @Sendable () -> Void
        private let lock = NSLock()
        private var pending: DispatchWorkItem?

        init(_ name: String, unload: @escaping @Sendable () -> Void) {
            self.name = name
            self.unload = unload
        }

        /// The model just ran (or loaded): unload it `delay` seconds from now unless it runs again.
        func touch(delay: TimeInterval = OnnxHost.idleSeconds) {
            let unload = self.unload, name = self.name
            let item = DispatchWorkItem {
                NSLog("Atelier: %@ unloaded after %.0f s idle", name, delay)
                unload()
            }
            lock.withLock {
                pending?.cancel()
                pending = item
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
        }

        func cancel() {
            lock.withLock {
                pending?.cancel()
                pending = nil
            }
        }
    }

    /// Unloads every model now (memory warning, a photo or Lens Blur closed). A run in progress
    /// finishes first; the next run loads its model again.
    public static func unloadAll() {
        FineEdges.unloadSession()
        DepthMap.unloadSession()
        AIDenoise.unloadSession()
    }
}
