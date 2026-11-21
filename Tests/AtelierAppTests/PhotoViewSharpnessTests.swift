import AppKit
import AtelierCore
import Combine
import SwiftUI
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

    /// A 16 × 16 copy of a picture's pixels: two copies of the same picture match, a thumbnail
    /// and the preview (or two different photos) don't.
    private static func fingerprint(of contents: Any?) -> [UInt8]? {
        guard let contents else { return nil }
        let object = contents as AnyObject
        guard CFGetTypeID(object) == CGImage.typeID else { return nil }
        let image = object as! CGImage
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func samePicture(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a, let b, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
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

    /// A pinch leaves the zoom anywhere, so the part in view rarely starts on a whole photo pixel:
    /// the frame must still line up with the full-size image that replaces it at rest.
    func testDragAtAPinchedZoomStaysAligned() async throws {
        try await drag(.contrast, magnification: 0.83) { start, tick in start + Double(tick) * 0.25 }
    }

    /// 2 s of a slider at 60 Hz through the slider's own entry point, zoomed to 100%, then 1.5 s
    /// at rest: no soft sample, no flicker (the picture on top switching between the frame and the
    /// canvas mid-drag, or showing an older tick than before).
    private func drag(_ parameter: DevelopSettings.Parameter, magnification: CGFloat = 1.0,
                      value: (Double, Int) -> Double) async throws {
        let harness = try await makeHarness()
        let develop = harness.develop, view = harness.view
        try await pinch(harness, to: magnification)
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
        // A frame of the part in view must sit on whole photo pixels, as the full-size image that
        // replaces it at rest does: otherwise the photo moves a pixel or two when the drag ends.
        var misplaced: [String] = []
        let photoWidth = CGFloat(develop.fullImage?.size.width ?? 0)
        let photoHeight = CGFloat(develop.fullImage?.size.height ?? 0)
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
            let frameLayer = view.liveFrameLayer, canvasBounds = frameLayer.superlayer?.bounds ?? .zero
            if now.top == .frame, photoWidth > 0, canvasBounds.width > 0, frameLayer.frame.width < canvasBounds.width - 1 {
                // The full-size image is stretched over the canvas: each axis by its own scale.
                let perX = photoWidth / canvasBounds.width, perY = photoHeight / canvasBounds.height
                let edges = [frameLayer.frame.minX * perX, frameLayer.frame.minY * perY,
                             frameLayer.frame.maxX * perX, frameLayer.frame.maxY * perY]
                if let off = edges.map({ abs($0 - $0.rounded()) }).max(), off > 0.02 {
                    misplaced.append("\(label): frame edges \(edges.map { String(format: "%.2f", $0) }) photo px")
                }
            }
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
        print("SHARPNESS \(parameter) drag: \(misplaced.count) frames off the photo's pixels")
        XCTAssertEqual(misplaced.count, 0, misplaced.first ?? "")
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
        var totalSwaps = 0
        var lines: [String] = []
        for index in [1, 3, 0] {
            let old = sample(view).contents
            var soft: [String] = []
            var kinds: [String: Int] = [:]
            let clicked = CACurrentMediaTime()
            model.focusedID = harness.ids[index]
            var newSharpAt: Double?
            var sharpSamples = 0
            // Each different picture of the new photo that reached the screen: one means it came
            // on in one step; more is a visible swap (the stored preview, then the render).
            var newPictures: [ObjectIdentifier] = []
            while CACurrentMediaTime() - clicked < 4 {
                try await Task.sleep(for: .milliseconds(5))
                let now = sample(view)
                let ms = (CACurrentMediaTime() - clicked) * 1000
                let isOld = now.contents != nil && now.contents === old
                let kind = isOld ? (now.soft ? "old photo, soft" : "old photo") : (now.soft ? "new photo, soft" : "new photo, sharp")
                kinds[kind, default: 0] += 1
                if !isOld, let contents = now.contents, newPictures.last != ObjectIdentifier(contents) {
                    newPictures.append(ObjectIdentifier(contents))
                }
                if now.soft { soft.append(String(format: "%.0f ms: ", ms) + kind + " — " + now.line) }
                if !isOld, !now.soft {
                    if newSharpAt == nil { newSharpAt = ms }
                    sharpSamples += 1
                    if sharpSamples > 60 { break }
                }
            }
            totalSoft += soft.count
            totalSwaps += max(0, newPictures.count - 1)
            let line = "[\(onChange)\(zoomFirst ? ", zoomed" : ", Fit")] to \(harness.names[index]) at \(model.zoomState.level): "
                + "click to sharp " + (newSharpAt.map { String(format: "%.0f ms", $0) } ?? "never") + "; "
                + "\(newPictures.count) picture(s) of the new photo; "
                + kinds.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
            lines.append(line)
            print("SHARPNESS \(line)")
            for s in soft.prefix(8) { print("SHARPNESS   \(s)") }
            XCTAssertNotNil(newSharpAt, "\(harness.names[index]) never showed sharp")
            try await Task.sleep(for: .milliseconds(1200))
        }
        XCTAssertEqual(totalSoft, 0, lines.joined(separator: "\n"))
        XCTAssertEqual(totalSwaps, 0, "the new photo swapped pictures on screen:\n" + lines.joined(separator: "\n"))
    }

    // MARK: Loupe

    /// Loupe, at Fit: each photo change puts one picture of the new photo on screen (its 2560 px
    /// preview), never the grid thumbnail and then the preview. Hosts the real `LoupeView`.
    func testLoupePhotoChangeShowsOnePicture() async throws {
        try await loupePhotoChanges(zoomed: false)
    }

    /// Zoomed in, the next photo goes on once at full size, not its preview blown up first.
    func testZoomedLoupePhotoChangeShowsOnePicture() async throws {
        try await loupePhotoChanges(zoomed: true)
    }

    private func loupePhotoChanges(zoomed: Bool) async throws {
        let key = LibraryModel.ZoomOnPhotoChange.key
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set("keep", forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["ATELIER_SHARPNESS_FOLDER"] else { throw XCTSkip("ATELIER_SHARPNESS_FOLDER not set") }
        // Far apart in the list, so the photo clicked is not a neighbour whose preview is
        // decoded ahead (`prefetchNeighbourPreviews`).
        let names = (env["ATELIER_LOUPE_FILES"]
            ?? "_RZF0502.NEF,_RZF0503.NEF,_RZF0504.NEF,_RZF0505.NEF,_RZF0506.NEF,_RZF0507.NEF,_RZF0508.NEF,_RZF0509.NEF")
            .split(separator: ",").map(String.init)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("LoupeSharpness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let catalog = try Catalog(packageURL: work.appendingPathComponent("Loupe.atelier"))
        let previews = PreviewCache(rootURL: try XCTUnwrap(catalog.previewsURL))
        // As the app does on launch, so the model doesn't discard the previews made below.
        previews.discardIfOutdated()
        var ids: [Int64] = []
        for name in names {
            let file = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let imported = await Importer(catalog: catalog, previews: nil).run(sources: [file], options: ImportOptions(buildPreviews: false))
            let id = try XCTUnwrap(imported.importedAssetIDs.first)
            try previews.generate(for: id, from: file)
            ids.append(id)
        }
        let model = LibraryModel(catalog: catalog)
        try await wait("the rows", seconds: 20) { model.rows.count >= ids.count }
        // Every photo's 2560 px preview on disk, as after an import has finished.
        try await wait("the previews", seconds: 120) {
            ids.allSatisfy { previews.has(.preview, for: $0) && previews.has(.thumbnail, for: $0) }
        }
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1512, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: LoupeView(zoom: model.zoomState).environmentObject(model))
        addTeardownBlock { @MainActor in window.close() }
        model.focusedID = ids[0]
        model.mode = .loupe
        func photoView() -> ZoomScrollView? {
            var stack: [NSView] = window.contentView.map { [$0] } ?? []
            while let view = stack.popLast() {
                if let zoom = view as? ZoomScrollView { return zoom }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }
        try await wait("the Loupe photo", seconds: 20) { photoView().map { Self.width(of: $0.liveFrameLayer.superlayer?.contents) != nil } ?? false }
        try await Task.sleep(for: .milliseconds(800))
        let first = try XCTUnwrap(photoView())
        if zoomed {
            first.magnification = 1.0
            NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: first)
            try await wait("the full-size Loupe photo", seconds: 30) { (Self.width(of: photoView()?.liveFrameLayer.superlayer?.contents) ?? 0) > 2560 }
        } else if model.zoomState.level != .fit {
            model.zoomState.level = .fit
        }
        try await Task.sleep(for: .milliseconds(800))
        var totalSwaps = 0
        var lines: [String] = []
        // The library may still be writing previews for the new photos; a preview written while
        // it shows is rightly shown again. Wait until none has been written for a while.
        var lastRevision = PreviewRevision.shared.value
        var quietSince = Date()
        try await wait("previews to settle", seconds: 60) {
            if PreviewRevision.shared.value != lastRevision { lastRevision = PreviewRevision.shared.value; quietSince = Date() }
            return Date().timeIntervalSince(quietSince) > 2
        }
        // The Filmstrip has every photo's grid thumbnail in memory, as in the app.
        for (index, id) in ids.enumerated() {
            var loaded = false
            ThumbnailLoader.shared.load(id, from: previews.url(for: id, size: .thumbnail)) { _ in loaded = true }
            try await wait("thumbnail \(index)", seconds: 10) { loaded }
        }
        // Which photo a picture on screen is, by its pixels against each photo's stored preview
        // and thumbnail.
        let known: [(String, [UInt8]?)] = ids.enumerated().flatMap { index, id -> [(String, [UInt8]?)] in
            let preview = ThumbnailLoader.decode(previews.url(for: id, size: .preview))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let thumbnail = ThumbnailLoader.decode(previews.url(for: id, size: .thumbnail))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return [("\(names[index]) preview", Self.fingerprint(of: preview)), ("\(names[index]) thumbnail", Self.fingerprint(of: thumbnail))]
        }
        func identify(_ print: [UInt8]?) -> String {
            known.first { Self.samePicture($0.1, print) }?.0 ?? "unknown"
        }
        for index in [4, 7, 2, 5] {
            let view = try XCTUnwrap(photoView())
            let old = view.liveFrameLayer.superlayer?.contents as AnyObject?
            var pictures: [String] = []
            var lastID: ObjectIdentifier?
            var lastPrint: [UInt8]?
            let oldPrint = Self.fingerprint(of: old)
            let clicked = CACurrentMediaTime()
            model.focusedID = ids[index]
            while CACurrentMediaTime() - clicked < (zoomed ? 3 : 1.5) {
                try await Task.sleep(for: .milliseconds(5))
                guard let contents = photoView()?.liveFrameLayer.superlayer?.contents as AnyObject?, contents !== old else { continue }
                if lastID != ObjectIdentifier(contents) {
                    lastID = ObjectIdentifier(contents)
                    // Another copy of the same pixels is no change on screen, and a copy of the
                    // last photo is still the last photo.
                    let print = Self.fingerprint(of: contents)
                    if pictures.isEmpty, Self.samePicture(print, oldPrint) { continue }
                    if pictures.isEmpty || !Self.samePicture(print, lastPrint) {
                        pictures.append(String(format: "%.0f ms: %d px ", (CACurrentMediaTime() - clicked) * 1000, Self.width(of: contents) ?? 0)
                                        + identify(print))
                    }
                    lastPrint = print
                }
            }
            totalSwaps += max(0, pictures.count - 1)
            let line = "Loupe\(zoomed ? " zoomed" : "") to \(names[index]): \(pictures.count) picture(s) — " + pictures.joined(separator: ", ")
            lines.append(line)
            print("SHARPNESS \(line)")
            XCTAssertFalse(pictures.isEmpty, "\(names[index]) never showed")
            if zoomed, let firstPicture = pictures.first {
                XCTAssertTrue(firstPicture.contains("6048 px") || firstPicture.contains("4032 px"), "zoomed in, the first picture was \(firstPicture)")
            }
        }
        XCTAssertEqual(totalSwaps, 0, lines.joined(separator: "\n"))
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
