import AppKit
import ImageIO
import AtelierCore
import IOSurface
import XCTest
@testable import AtelierApp

/// A zoomed slider drag on a real RAW must never show the stretched proxy (AT-089; Rosh, Nov 21,
/// 2026: "unnecessarily draws the lower resolution and then draw higher resolution"). Drives
/// `DevelopController` and a `ZoomScrollView` attached through `photoFeed` the way the Develop
/// view does, in a window that is never put on screen, zooms in the way a pinch ends, waits for
/// the full-size image, then drags Contrast for 2 s at 60 Hz and samples what is on top of the
/// photo view at every tick. Needs ATELIER_ZOOM_RAW (and optionally ATELIER_ZOOM_SETTINGS, a
/// DevelopSettings JSON file); skipped without it.
final class ZoomedDragSharpnessTests: XCTestCase {
    private enum Top: String { case detail, frame, canvasFull = "canvas full-size", canvasProxy = "canvas proxy", empty }

    private static func width(of contents: Any?) -> Int? {
        guard let contents else { return nil }
        let object = contents as AnyObject
        if CFGetTypeID(object) == CGImage.typeID { return (object as! CGImage).width }
        if let surface = object as? IOSurface { return surface.width }
        return nil
    }

    @MainActor
    func testZoomedContrastDragNeverShowsTheProxy() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawPath = env["ATELIER_ZOOM_RAW"] else { throw XCTSkip("ATELIER_ZOOM_RAW not set") }
        let raw = URL(fileURLWithPath: rawPath)
        let base: DevelopSettings? = try env["ATELIER_ZOOM_SETTINGS"].map {
            try JSONDecoder().decode(DevelopSettings.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZoomedDrag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil).run(sources: [raw], options: ImportOptions(buildPreviews: false))
        let assetID = try XCTUnwrap(result.importedAssetIDs.first)
        if let base { try catalog.saveDevelopSettings(base, for: assetID) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(raw as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let assetSize = CGSize(width: properties[kCGImagePropertyPixelWidth] as? Int ?? 6048,
                               height: properties[kCGImagePropertyPixelHeight] as? Int ?? 4032)

        let controller = DevelopController(catalog: catalog, previews: PreviewCache(rootURL: folder.appendingPathComponent("Previews")))
        // Never ordered in: nothing reaches the screen, but the view has a window, as on screen.
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
        defer { view.feed?.detach(view); window.close() }

        var level = ZoomLevel.fit
        view.onZoomChange = { level = $0 }
        // As DevelopView.onZoomReport.
        view.onReport = { report in
            let wants = level != .fit && report.isZoomedPastFit
            if controller.wantsFullResolution != wants { controller.wantsFullResolution = wants }
        }
        view.feed = controller.photoFeed
        controller.photoFeed.attach(view)
        // As SwiftUI's updateNSView after each change the controller publishes.
        let pixelSize = controller.croppedPixelSize(assetSize: assetSize)
        var updates = 0
        let update = {
            updates += 1
            view.isUpdating = true
            view.setImage(controller.displayImage, pixelSize: pixelSize)
            view.apply(level)
            view.isUpdating = false
        }
        let observer = controller.objectWillChange.sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
        }
        defer { observer.cancel() }

        controller.open(assetID)
        try await wait("the proxy", seconds: 20) { controller.image != nil }
        update()
        try await Task.sleep(for: .milliseconds(500))

        // A pinch: magnification set live, then the end of the gesture.
        view.magnification = 1.0
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: view)
        try await wait("wantsFullResolution", seconds: 5) { controller.wantsFullResolution }
        try await wait("the full-size image on screen", seconds: 30) {
            controller.fullImage != nil && Self.width(of: view.liveFrameLayer.superlayer?.contents) == Int(assetSize.width)
        }
        try await Task.sleep(for: .milliseconds(600))
        let backing = window.backingScaleFactor
        let target = controller.photoFeed.detailTarget
        print("ZDRAG magnification \(view.magnification), level \(level), backing \(backing), target \(String(describing: target))")

        var counts: [Top: Int] = [:]
        var soft: [String] = []
        var transitions: [String] = []
        var last: Top?
        var behind: [String] = []
        var sawDetail = false
        func sample(_ label: String) {
            let canvas = view.liveFrameLayer.superlayer
            let frame = view.liveFrameLayer, detail = view.detailFrameLayer
            let canvasWidth = Self.width(of: canvas?.contents)
            let frameWidth = Self.width(of: frame.contents)
            let detailWidth = Self.width(of: detail.contents)
            let top: Top
            if !detail.isHidden, detailWidth != nil { top = .detail }
            else if !frame.isHidden, frameWidth != nil { top = .frame }
            else if let canvasWidth { top = canvasWidth >= Int(assetSize.width) ? .canvasFull : .canvasProxy }
            else { top = .empty }
            counts[top, default: 0] += 1
            let line = "\(label): top \(top.rawValue); canvas \(canvasWidth.map(String.init) ?? "-") px; frame "
                + "\(frame.isHidden ? "hidden" : "shown") \(frameWidth.map(String.init) ?? "-") px; detail "
                + "\(detail.isHidden ? "hidden" : "shown") \(detailWidth.map(String.init) ?? "-") px \(detail.frame)"
            if top == .frame || top == .canvasProxy || top == .empty { soft.append(line) }
            // Once a detail frame has shown, the full-size image under it is a step behind: the
            // edit would flick back to an older value until the next detail frame.
            if label.hasPrefix("tick"), sawDetail, top == .canvasFull { behind.append(line) }
            if top == .detail { sawDetail = true }
            if top != last { transitions.append(line); last = top }
        }

        // 2 s of Contrast at 60 Hz through the slider's own entry point, then 1.5 s at rest.
        let start = controller.sliderValue(.contrast)
        let clock = ContinuousClock()
        var next = clock.now
        for tick in 0..<120 {
            controller.setSlider(.contrast, to: start + Double(tick) * 0.25)
            next += .milliseconds(16)
            try await Task.sleep(until: next, clock: clock)
            sample("tick \(tick)")
        }
        for rest in 0..<90 {
            next += .milliseconds(16)
            try await Task.sleep(until: next, clock: clock)
            sample("rest \(rest)")
        }
        print("ZDRAG counts \(counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ", ")), updates \(updates)")
        for line in transitions { print("ZDRAG change \(line)") }
        for line in soft.prefix(40) { print("ZDRAG SOFT \(line)") }
        print("ZDRAG soft \(soft.count), behind (older value under a missing detail frame) \(behind.count)")
        XCTAssertEqual(behind.count, 0, "\(behind.count) drag samples showed the older full-size image; first: \(behind.first ?? "")")
        XCTAssertEqual(soft.count, 0, "\(soft.count) soft samples; first: \(soft.first ?? "")")
    }

    @MainActor
    private func wait(_ what: String, seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); throw XCTSkip("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
