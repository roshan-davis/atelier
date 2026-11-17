import Darwin
import Foundation
import OnnxRuntimeBindings

/// Runs Atelier's ONNX models (Fine Edges, Depth, AI Denoise) in a helper process, the standard
/// macOS way to keep memory-hungry work out of an app (AT-077, review items M1, R1 and C1).
///
/// Why: ONNX Runtime keeps the working memory of a run and, through its Objective-C API, can't be
/// told to give it back. Mac check 4 of PR #157 (Nov 16, 2026, Z f NEF, 48 GB Mac): one Fine
/// Edges Fast run added about 18 GB and kept 13 GB afterwards; Hair Detail added about 46 GB.
/// In the app's own process that memory stayed until the model was unloaded, and on top of the
/// photo's own it froze the Mac. In a helper, it belongs to the helper: when the helper quits,
/// macOS takes all of it back, whatever the runtime did with it; and if a run needs more than
/// the Mac has, macOS stops the helper, not Atelier, and the tool says it couldn't run.
///
/// The helper is Atelier's own executable started with `helperArgument` (so it is always there,
/// in the built app and when run from Xcode, with no second target to build). Each model has
/// its own helper (`fineEdges`, `depth`, `denoise`), started on its first run, kept while it is
/// in use and quit `idleSeconds` after its last run, when a photo or Lens Blur closes, on
/// leaving Develop and on macOS memory warnings (`RenderMemory.releaseAll`). Messages are a
/// small JSON header and the tensor's bytes over the helper's standard input and output.
///
/// Where no Atelier executable is found (AtelierCore's own tests), the same code runs in this
/// process instead (`runHere`).
public final class ModelRunner: @unchecked Sendable {
    public static let fineEdges = ModelRunner(name: "Fine Edges")
    public static let depth = ModelRunner(name: "Depth")
    public static let denoise = ModelRunner(name: "AI Denoise")
    static var all: [ModelRunner] { [fineEdges, depth, denoise] }

    /// The argument that starts Atelier's executable as a model helper (`AtelierMain`).
    public static let helperArgument = "--atelier-model-runner"
    /// How long a helper stays after its last run. Starting one again and loading its model
    /// takes about half a second (Depth, Fast) to a few seconds (Hair Detail); mattes and depth
    /// maps once found are kept by their own caches, so most edits never run a model again.
    public static let idleSeconds: TimeInterval = 30

    /// What to run: the model file, how to make its session, and the input's shape. The input
    /// and output are float tensors (the output may come back as half floats; callers check
    /// its size).
    public struct Request: Codable, Sendable {
        public var modelPath: String
        /// Graph optimization levels to try in order ("none", "basic", "extended", "all"): a
        /// later one is used only if making the session with the earlier one fails.
        public var optimizationLevels: [String]
        /// Core ML provider options; nil runs on ONNX Runtime's CPU code. If Core ML refuses the
        /// model, the CPU is used.
        public var coreML: [String: String]?
        /// The CPU's thread count (nil: ONNX Runtime's own choice).
        public var threads: Int?
        public var inputName: String?
        public var outputName: String?
        public var shape: [Int]

        public init(modelPath: String, optimizationLevels: [String], coreML: [String: String]? = nil, threads: Int? = nil,
                    inputName: String? = nil, outputName: String? = nil, shape: [Int]) {
            self.modelPath = modelPath
            self.optimizationLevels = optimizationLevels
            self.coreML = coreML
            self.threads = threads
            self.inputName = inputName
            self.outputName = outputName
            self.shape = shape
        }

        /// What identifies the session the request needs (a helper keeps one).
        var sessionKey: String { "\(modelPath)|\(optimizationLevels)|\(coreML?.sorted { $0.key < $1.key } ?? [])|\(threads ?? 0)" }
    }

    /// A run's result: the output tensor's bytes, and whether Core ML ran it.
    public struct Output: Sendable {
        public var data: Data
        public var usedCoreML: Bool
    }

    public struct Failure: LocalizedError {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }

    private struct Reply: Codable {
        var error: String?
        var usedCoreML: Bool
    }

    public let name: String
    private let lock = NSLock()
    private var helper: Helper?
    private var idle: DispatchWorkItem?

    private init(name: String) {
        self.name = name
    }

    // MARK: Client

    /// Runs `request` on `input` in this model's helper (started if needed), waiting for any
    /// run already in progress. Call it off the main thread.
    public func run(_ request: Request, input: Data) throws -> Output {
        guard let executable = Self.executableURL else { return try Self.runHere(request, input: input) }
        return try lock.withLock {
            idle?.cancel()
            idle = nil
            defer { scheduleIdleQuit() }
            let header = try JSONEncoder().encode(request)
            for attempt in 0..<2 {
                let running: Helper
                if let helper { running = helper } else {
                    running = try Helper(executable: executable)
                    helper = running
                }
                do {
                    try Wire.send(running.input, header: header, payload: input)
                    guard let answer = try Wire.receive(running.output) else {
                        throw Failure("the model's helper stopped")
                    }
                    let reply = try JSONDecoder().decode(Reply.self, from: answer.header)
                    if let error = reply.error { throw Failure(error) }
                    return Output(data: answer.payload, usedCoreML: reply.usedCoreML)
                } catch let failure as Failure where failure.reason == "the model's helper stopped" || failure.reason == Wire.brokenPipe {
                    // The helper quit (macOS stopped it, or it crashed): say so, or start a new one
                    // once if it had quit before this run started.
                    let status = running.stop()
                    helper = nil
                    if attempt == 0, status.wasIdleExit { continue }
                    NSLog("Atelier: %@'s helper stopped (%@)", name, status.description)
                    throw Failure(status.killed
                        ? "this Mac ran out of memory for it (macOS stopped the model)"
                        : "the model stopped unexpectedly (\(status.description))")
                }
            }
            throw Failure("the model's helper couldn't start")
        }
    }

    /// Quits this model's helper now, giving all its memory back. Waits for a run in progress.
    public func stop() {
        lock.withLock {
            idle?.cancel()
            idle = nil
            _ = helper?.stop()
            helper = nil
        }
    }

    /// Whether the helper is running now (tests).
    var isRunning: Bool { lock.withLock { helper != nil } }

    /// Call with the lock held.
    private func scheduleIdleQuit() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSLog("Atelier: %@'s helper quit after %.0f s idle", self.name, Self.idleSeconds)
            self.stop()
        }
        idle = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleSeconds, execute: item)
    }

    /// Quits every model's helper (memory warning, a photo or Lens Blur closed, Develop left).
    public static func stopAll() {
        for runner in all { runner.stop() }
    }

    /// Atelier's executable, which runs as the helper: the app itself, or (in tests) the
    /// AtelierApp built next to the test bundle. Nil runs models in this process.
    nonisolated(unsafe) static var executableURL: URL? = {
        if let path = ProcessInfo.processInfo.environment["ATELIER_MODEL_RUNNER"] {
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
        if let main = Bundle.main.executableURL, main.lastPathComponent == "AtelierApp" { return main }
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            let sibling = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("AtelierApp")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return nil
    }()

    /// One running helper process and its pipes.
    private final class Helper {
        let process = Process()
        let input: Int32
        let output: Int32
        private let toHelper = Pipe()
        private let fromHelper = Pipe()

        init(executable: URL) throws {
            // Writing to a helper macOS has stopped must fail with EPIPE, not stop Atelier.
            signal(SIGPIPE, SIG_IGN)
            process.executableURL = executable
            process.arguments = [ModelRunner.helperArgument]
            process.standardInput = toHelper
            process.standardOutput = fromHelper
            process.standardError = FileHandle.standardError
            try process.run()
            input = toHelper.fileHandleForWriting.fileDescriptor
            output = fromHelper.fileHandleForReading.fileDescriptor
        }

        struct Status {
            var killed: Bool
            var wasIdleExit: Bool
            var description: String
        }

        /// Closes its input (it quits when its input ends) and waits for it.
        func stop() -> Status {
            try? toHelper.fileHandleForWriting.close()
            if process.isRunning {
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline { usleep(10_000) }
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            try? fromHelper.fileHandleForReading.close()
            let killed = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
            return Status(killed: killed,
                          wasIdleExit: process.terminationReason == .exit && process.terminationStatus == 0,
                          description: "\(process.terminationReason == .exit ? "exit" : "signal") \(process.terminationStatus)")
        }
    }

    // MARK: Helper

    /// The helper's loop: reads requests from standard input and answers on standard output until
    /// its input ends. Started by `AtelierMain` when Atelier is launched with `helperArgument`.
    public static func serve() -> Never {
        // Answers go to a private copy of standard output; anything printed goes to standard
        // error, so a stray print can't break a message.
        let answers = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        while true {
            let received: (header: Data, payload: Data)?
            do { received = try Wire.receive(STDIN_FILENO) } catch { exit(1) }
            guard let message = received else { exit(0) }
            var reply = Reply(error: nil, usedCoreML: false)
            var output = Data()
            do {
                let request = try JSONDecoder().decode(Request.self, from: message.header)
                let result = try runHere(request, input: message.payload)
                output = result.data
                reply.usedCoreML = result.usedCoreML
            } catch {
                reply.error = error.localizedDescription
            }
            do {
                try Wire.send(answers, header: JSONEncoder().encode(reply), payload: output)
            } catch {
                exit(1)
            }
        }
    }

    private static let hereLock = NSLock()
    nonisolated(unsafe) private static var environment: ORTEnv?
    /// The session this process keeps (one: a helper runs one model).
    nonisolated(unsafe) private static var loaded: (key: String, session: ORTSession, usedCoreML: Bool)?

    /// Runs `request` in this process: in the helper, or where there is no helper.
    static func runHere(_ request: Request, input: Data) throws -> Output {
        try hereLock.withLock {
            let (session, usedCoreML) = try session(for: request)
            let value = try ORTValue(tensorData: NSMutableData(data: input), elementType: .float,
                                     shape: request.shape.map { NSNumber(value: $0) })
            guard let inputName = try request.inputName ?? session.inputNames().first,
                  let outputName = try request.outputName ?? session.outputNames().first
            else { throw Failure("the model has no inputs or outputs") }
            let outputs = try session.run(withInputs: [inputName: value], outputNames: [outputName], runOptions: nil)
            guard let result = outputs[outputName] else { throw Failure("the model gave no output") }
            return Output(data: try result.tensorData() as Data, usedCoreML: usedCoreML)
        }
    }

    /// Unloads the session this process keeps (where models run here).
    static func unloadHere() {
        hereLock.withLock { loaded = nil }
    }

    /// Call with `hereLock` held.
    private static func session(for request: Request) throws -> (ORTSession, Bool) {
        let key = request.sessionKey
        if let loaded, loaded.key == key { return (loaded.session, loaded.usedCoreML) }
        loaded = nil
        let env = try environment ?? ORTEnv(loggingLevel: .warning)
        environment = env
        func options(level: String, coreML: [String: String]?) throws -> ORTSessionOptions {
            let options = try ORTSessionOptions()
            let levels: [String: ORTGraphOptimizationLevel] = ["none": .none, "basic": .basic, "extended": .extended, "all": .all]
            try options.setGraphOptimizationLevel(levels[level] ?? .basic)
            if let threads = request.threads { try options.setIntraOpNumThreads(Int32(threads)) }
            if let coreML {
                if let cache = coreML["ModelCacheDirectory"] {
                    try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
                }
                try options.appendCoreMLExecutionProvider(withOptionsV2: coreML)
            }
            return options
        }
        let levels = request.optimizationLevels.isEmpty ? ["basic"] : request.optimizationLevels
        var attempts: [(level: String, coreML: [String: String]?)] = []
        if let coreML = request.coreML { attempts.append((levels[0], coreML)) }
        attempts += levels.map { ($0, nil) }
        var lastError: Error = Failure("no session options to try")
        for attempt in attempts {
            do {
                let made = try ORTSession(env: env, modelPath: request.modelPath,
                                          sessionOptions: options(level: attempt.level, coreML: attempt.coreML))
                loaded = (key, made, attempt.coreML != nil)
                return (made, attempt.coreML != nil)
            } catch {
                NSLog("Atelier: %@ (optimization %@, %@) failed to load: %@", (request.modelPath as NSString).lastPathComponent,
                      attempt.level, attempt.coreML == nil ? "CPU" : "Core ML", "\(error)")
                lastError = error
            }
        }
        throw lastError
    }
}

/// Length-prefixed messages over file descriptors: a 4-byte header length, the header, an
/// 8-byte payload length, the payload (little-endian).
enum Wire {
    static let brokenPipe = "the model's helper isn't reading"

    static func send(_ fd: Int32, header: Data, payload: Data) throws {
        var headerCount = UInt32(header.count).littleEndian
        var payloadCount = UInt64(payload.count).littleEndian
        try write(fd, Data(bytes: &headerCount, count: 4))
        try write(fd, header)
        try write(fd, Data(bytes: &payloadCount, count: 8))
        try write(fd, payload)
    }

    /// The next message, or nil when the other side closed before one began.
    static func receive(_ fd: Int32) throws -> (header: Data, payload: Data)? {
        guard let headerCount = try read(fd, count: 4, endIsFine: true) else { return nil }
        let header = try read(fd, count: Int(headerCount.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian))
        let payloadCount = try read(fd, count: 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        return (header, try read(fd, count: Int(payloadCount)))
    }

    private static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ModelRunner.Failure(errno == EPIPE ? brokenPipe : "writing to the model's helper failed (\(errno))")
                }
                offset += written
            }
        }
    }

    private static func read(_ fd: Int32, count: Int) throws -> Data {
        guard let data = try read(fd, count: count, endIsFine: false) else { throw ModelRunner.Failure("the model's helper stopped") }
        return data
    }

    private static func read(_ fd: Int32, count: Int, endIsFine: Bool) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            while offset < count {
                let got = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw ModelRunner.Failure("the model's helper stopped")
                }
                if got == 0 { break }
                offset += got
            }
        }
        if offset == 0, endIsFine { return nil }
        guard offset == count else { throw ModelRunner.Failure("the model's helper stopped") }
        return data
    }
}
