import AppKit
import AtelierCore
import Combine
import ImageIO
import IOSurface
import XCTest
@testable import AtelierApp

/// The Develop photo view never shows a picture softer than the view needs, never steps back to
/// an older edit, and never flickers between pictures (Rosh, Nov 21, 2026). Drives the real
/// `LibraryModel` and `DevelopController` with a `ZoomScrollView` wired the way
/// `ZoomableImageView` and `DevelopView` wire it, in a window that is never put on screen, and
/// samples what is on top of the photo view.
///
/// A sample is soft when the picture on top has fewer than 90% of the screen pixels it covers
/// (the 2560-pixel proxy at Fit in a ~2700-pixel view passes; the proxy or an old photo blown up
/// to 100%, or the 256-pixel grid thumbnail, fail).
///
/// Needs real RAW files: ATELIER_SHARPNESS_FOLDER (at least four RAWs, ATELIER_SHARPNESS_FILES
/// to pick them) and optionally ATELIER_SHARPNESS_SETTINGS (a DevelopSettings JSON for the
/// first). Skipped without them. Run with HOME and CFFIXED_USER_HOME set to a scratch folder so
/// the Develop timing log stays out of ~/Documents.
@MainActor
final class PhotoViewSharpnessTests: XCTestCase {
    private struct Harness {
        let model: LibraryModel
        let develop: DevelopController
        let view: ZoomScrollView
        let window: NSWindow
        let ids: [Int64]
        let names: [String]
        let observers: [AnyCancellable]
    }

    private enum Top: String { case frame, canvas, empty }

    private struct Sample {
        let top: Top
        /// Picture pixels per screen pixel over the part of the view it covers.
        let density: Double
        let contentWidth: Int
        let contents: AnyObject?
        var soft: Bool { top == .empty || density < 0.9 }
        var line: String { "\(top.rawValue) \(contentWidth) px, \(String(format: "%.2f", density)) px per screen px" }
    }

    private static func width(of contents: Any?) -> Int? {
        guard let contents else { return nil }
        let object = contents as AnyObject
        if CFGetTypeID(object) == CGImage.typeID { return (object as! CGImage).width }
        if let surface = object as? IOSurface { return surface.width }
        return nil
    }

    private func sample(_ view: ZoomScrollView) -> Sample {
        let frame = view.liveFrameLayer
        let canvas = frame.superlayer
        let scale = view.magnification * (view.window?.backingScaleFactor ?? 2)
        if !frame.isHidden, let width = Self.width(of: frame.contents), frame.bounds.width > 0 {
            return Sample(top: .frame, density: Double(CGFloat(width) / (frame.bounds.width * scale)),
                          contentWidth: width, contents: frame.contents as AnyObject?)
        }
        if let canvas, let width = Self.width(of: canvas.contents), canvas.bounds.width > 0 {
            return Sample(top: .canvas, density: Double(CGFloat(width) / (canvas.bounds.width * scale)),
                          contentWidth: width, contents: canvas.contents as AnyObject?)
        }
        return Sample(top: .empty, density: 0, contentWidth: 0, contents: nil)
    }

    private func makeHarness(onChange: String = "keep") async throws -> Harness {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["ATELIER_SHARPNESS_FOLDER"] else { throw XCTSkip("ATELIER_SHARPNESS_FOLDER not set") }
        let names = (env["ATELIER_SHARPNESS_FILES"] ?? "_RZF0502.NEF,_RZF0503.NEF,_RZF0504.NEF,_RZF0560.NEF")
            .split(separator: ",").map(String.init)
        let files = names.map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        let base: DevelopSettings? = try env["ATELIER_SHARPNESS_SETTINGS"].map {
            try JSONDecoder().decode(DevelopSettings.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoViewSharpness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let catalog = try Catalog(packageURL: work.appendingPathComponent("Sharpness.atelier"))
        var ids: [Int64] = []
        for file in files {
            let imported = await Importer(catalog: catalog, previews: nil).run(sources: [file], options: ImportOptions(buildPreviews: false))
            ids.append(try XCTUnwrap(imported.importedAssetIDs.first, "could not import \(file.lastPathComponent)"))
        }
        if let base { try catalog.saveDevelopSettings(base, for: ids[0]) }

        let key = LibraryModel.ZoomOnPhotoChange.key
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(onChange, forKey: key)
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: key) }

        let model = LibraryModel(catalog: catalog)
        let develop = model.develop
        let zoom = model.zoomState
        // Never ordered in: nothing reaches the screen, but the view is in a window, as on screen.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1512, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let view = ZoomScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 1512, height: 900)
        window.contentView = NSView(frame: view.frame)
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(view)
        addTeardownBlock { @MainActor in view.feed?.detach(view); window.close() }

        // As ZoomableImageView.updateNSView and DevelopView.onZoomReport.
        view.onZoomChange = { level in if zoom.level != level { zoom.level = level } }
        view.onReport = { report in
            if model.zoomReport != report { model.zoomReport = report }
            let wants = zoom.level != .fit && report.isZoomedPastFit
            if develop.wantsFullResolution != wants { develop.wantsFullResolution = wants }
        }
        zoom.currentCenter = { [weak view] in view?.relativeCenter }
        zoom.focus = { [weak view] center in view?.focus(on: center) }
        view.viewport = zoom.viewport
        view.zoomState = zoom
        zoom.views.add(view)
        view.feed = develop.photoFeed
        develop.photoFeed.attach(view)
        let update = { @MainActor in
            let pixelSize: CGSize? = model.detail.flatMap { detail in
                guard let width = detail.asset.width, let height = detail.asset.height else { return nil }
                return develop.croppedPixelSize(assetSize: CGSize(width: width, height: height))
            }
            view.isUpdating = true
            view.show(develop.displayImage, pixelSize: pixelSize, zoom: zoom, holding: develop.holdsPreviousPhoto)
            view.isUpdating = false
        }
        let later = { DispatchQueue.main.async { MainActor.assumeIsolated { update() } } }
        let observers = [develop.objectWillChange.sink { _ in later() },
                         model.objectWillChange.sink { _ in later() },
                         zoom.objectWillChange.sink { _ in later() }]

        // The model loads its rows and restores its session first; open Develop after that.
        try await wait("the rows", seconds: 20) { model.rows.count >= ids.count }
        try await Task.sleep(for: .milliseconds(500))
        model.focusedID = ids[0]
        model.mode = .develop
        try await Task.sleep(for: .milliseconds(300))
        if model.mode != .develop { model.mode = .develop }
        try await wait("the first photo", seconds: 20) { develop.image != nil }
        update()
        try await Task.sleep(for: .milliseconds(500))
        return Harness(model: model, develop: develop, view: view, window: window, ids: ids, names: names,
                       observers: observers)
    }

    /// Zooms the way a pinch ends: magnification set live, then the end of the gesture.
    private func pinch(_ harness: Harness, to magnification: CGFloat) async throws {
        harness.view.magnification = magnification
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: harness.view)
        try await wait("sharp at \(magnification)", seconds: 30) {
            !self.sample(harness.view).soft && harness.develop.fullImage != nil
        }
        try await Task.sleep(for: .milliseconds(800))
    }

    // MARK: Drags

    func testZoomedContrastDragStaysSharp() async throws {
        try await drag(.contrast) { start, tick in start + Double(tick) * 0.25 }
    }

    func testZoomedExposureDragStaysSharp() async throws {
        try await drag(.exposure) { _, tick in -1 + 2 * Double(tick) / 119 }
    }

    /// 2 s of a slider at 60 Hz through the slider's own entry point, zoomed to 100%, then 1.5 s
    /// at rest: no soft sample, no flicker (the picture on top switching between the frame and the
    /// canvas mid-drag, or showing an older tick than before).
    private func drag(_ parameter: DevelopSettings.Parameter, value: (Double, Int) -> Double) async throws {
        let harness = try await makeHarness()
        let develop = harness.develop, view = harness.view
        try await pinch(harness, to: 1.0)
        var soft: [String] = [], flickers: [String] = []
        var lastTop: Top?
        var lastTick = -1
        var tickOfRender: [Int: Int] = [:]
        var values: [Double] = []
        var frameTicks = 0
        // When each new frame reached the screen, for frames per second and the longest gap.
        var frameTimes: [Double] = []
        var lastShown = develop.photoFeed.sink.shownCount
        // The histogram keeps counting the edit during the drag (`measuredRank` grows with it).
        var histogramUpdates = Set<Int>()
        func shownTick(_ sample: Sample) -> Int? {
            switch sample.top {
            case .frame: return tickOfRender[develop.photoFeed.sink.shownCount]
            case .canvas:
                guard let settings = Self.child("fullImageSettings", of: develop) as? DevelopSettings? , let settings else { return nil }
                return values.lastIndex(of: settings[parameter]) ?? -1
            case .empty: return nil
            }
        }
        func check(_ label: String, during: Bool) {
            let now = sample(view)
            if now.soft { soft.append("\(label): \(now.line)") }
            let tick = shownTick(now)
            if during {
                if let lastTop, lastTop != now.top, frameTicks > 0 { flickers.append("\(label): \(lastTop.rawValue) → \(now.line)") }
                if let tick, tick < lastTick { flickers.append("\(label): back to tick \(tick) from \(lastTick)") }
            }
            if let tick { lastTick = max(lastTick, tick) }
            if now.top == .frame { frameTicks += 1 }
            let shownCount = develop.photoFeed.sink.shownCount
            if during, let rank = Self.child("measuredRank", of: develop) as? Int { histogramUpdates.insert(rank) }
            if during, shownCount != lastShown { frameTimes.append(CACurrentMediaTime() * 1000); lastShown = shownCount }
            lastTop = now.top
        }
        let start = develop.sliderValue(parameter)
        let clock = ContinuousClock()
        var next = clock.now
        for tick in 0..<120 {
            develop.setSlider(parameter, to: value(start, tick))
            values.append(develop.settings[parameter])
            if let count = Self.child("renderCount", of: develop) as? Int { tickOfRender[count] = tick }
            next += .milliseconds(16)
            try await Task.sleep(until: next, clock: clock)
            check("tick \(tick)", during: true)
        }
        for rest in 0..<90 {
            next += .milliseconds(16)
            try await Task.sleep(until: next, clock: clock)
            check("rest \(rest)", during: false)
        }
        let gaps = zip(frameTimes.dropFirst(), frameTimes).map { $0 - $1 }.sorted()
        func pick(_ q: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count - 1) * q))] }
        print("SHARPNESS \(parameter) drag: \(soft.count) soft, \(flickers.count) flickers, \(frameTicks) frame samples; "
            + String(format: "%d new frames in 2 s, gap median %.0f ms, p95 %.0f ms, longest %.0f ms",
                     frameTimes.count, pick(0.5), pick(0.95), gaps.last ?? 0)
            + "; histogram updated \(histogramUpdates.count) times; peak memory \((RenderMemory.peakFootprint() ?? 0) >> 20) MB")
        for line in (soft + flickers).prefix(20) { print("SHARPNESS   \(line)") }
        XCTAssertEqual(soft.count, 0, soft.first ?? "")
        XCTAssertEqual(flickers.count, 0, flickers.first ?? "")
        XCTAssertGreaterThan(histogramUpdates.count, 5, "the histogram stood still during the drag")
    }

    // MARK: Photo changes

    func testPhotoChangeKeepingTheZoomIsNeverSoft() async throws {
        try await photoChanges(onChange: "keep", zoomFirst: true)
    }

    /// Rosh's setting: each photo goes back to the zoom it was left at, so a photo never zoomed
    /// opens at Fit and one left at 100% opens at 100% (from Fit, the soft flash Rosh saw).
    func testPhotoChangeReturningToEachZoomIsNeverSoft() async throws {
        try await photoChanges(onChange: "remember", zoomFirst: true)
    }

    func testPhotoChangeAtFitIsNeverSoft() async throws {
        try await photoChanges(onChange: "keep", zoomFirst: false)
    }

    /// Clicks through the photos the way the Filmstrip does (`LibraryModel.focusedID`): a
    /// neighbour (preloaded), a photo never opened or preloaded, and back to the first. Samples
    /// every 5 ms from the click until the new photo has been sharp for 300 ms.
    private func photoChanges(onChange: String, zoomFirst: Bool) async throws {
        let harness = try await makeHarness(onChange: onChange)
        let model = harness.model, view = harness.view
        if zoomFirst {
            try await pinch(harness, to: 1.0)
        } else if model.zoomState.level != .fit {
            model.zoomState.level = .fit
            try await wait("Fit", seconds: 10) { !harness.develop.wantsFullResolution }
            try await Task.sleep(for: .milliseconds(800))
        }
        var totalSoft = 0
        var lines: [String] = []
        for index in [1, 3, 0] {
            let old = sample(view).contents
            var soft: [String] = []
            var kinds: [String: Int] = [:]
            let clicked = CACurrentMediaTime()
            model.focusedID = harness.ids[index]
            var newSharpAt: Double?
            var sharpSamples = 0
            while CACurrentMediaTime() - clicked < 4 {
                try await Task.sleep(for: .milliseconds(5))
                let now = sample(view)
                let ms = (CACurrentMediaTime() - clicked) * 1000
                let isOld = now.contents != nil && now.contents === old
                let kind = isOld ? (now.soft ? "old photo, soft" : "old photo") : (now.soft ? "new photo, soft" : "new photo, sharp")
                kinds[kind, default: 0] += 1
                if now.soft { soft.append(String(format: "%.0f ms: ", ms) + kind + " — " + now.line) }
                if !isOld, !now.soft {
                    if newSharpAt == nil { newSharpAt = ms }
                    sharpSamples += 1
                    if sharpSamples > 60 { break }
                }
            }
            totalSoft += soft.count
            let line = "[\(onChange)\(zoomFirst ? ", zoomed" : ", Fit")] to \(harness.names[index]) at \(model.zoomState.level): "
                + "click to sharp " + (newSharpAt.map { String(format: "%.0f ms", $0) } ?? "never") + "; "
                + kinds.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
            lines.append(line)
            print("SHARPNESS \(line)")
            for s in soft.prefix(8) { print("SHARPNESS   \(s)") }
            XCTAssertNotNil(newSharpAt, "\(harness.names[index]) never showed sharp")
            try await Task.sleep(for: .milliseconds(1200))
        }
        XCTAssertEqual(totalSoft, 0, lines.joined(separator: "\n"))
    }

    // MARK: Helpers

    private static func child(_ name: String, of object: Any) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: object)
        while let current = mirror {
            if let value = current.children.first(where: { $0.label == name })?.value { return value }
            mirror = current.superclassMirror
        }
        return nil
    }

    private func wait(_ what: String, seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); throw XCTSkip("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
