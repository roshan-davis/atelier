import AppKit
import AtelierCore
import XCTest
@testable import AtelierApp
@testable import AtelierCore

/// The Lens Blur mode on a real RAW with the real depth model: every option changes the photo,
/// Show Overlay shows red every time, and how long each takes. Opt-in, as it needs a RAW and the
/// downloaded depth model: `ATELIER_LENS_BLUR_RAW=/path/to/photo.NEF swift test --filter
/// LensBlurRealPhotoTests`. The RAW is copied to a temporary folder first (Save writes a TIFF next
/// to it). Times are printed as `LENSBLUR:` lines; the test fails only on what doesn't work.
@MainActor
final class LensBlurRealPhotoTests: XCTestCase {
    private var folder: URL!
    private var catalog: Catalog!
    private var controller: DevelopController!
    private var assetID: Int64!
    /// The photo unblurred, as a 256 px RGBA thumbnail.
    private var sharp: [UInt8] = []
    private let showsOverlay = UserDefaults.standard.bool(forKey: "masks.showOverlay")

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["ATELIER_LENS_BLUR_RAW"] else {
            throw XCTSkip("Set ATELIER_LENS_BLUR_RAW to a RAW file to run")
        }
        try XCTSkipUnless(DepthMap.isInstalled, "The depth model isn't downloaded")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LensBlurReal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = folder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: raw)
        catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil).run(sources: [raw], options: ImportOptions(buildPreviews: false))
        assetID = try XCTUnwrap(result.importedAssetIDs.first)
        var settings = DevelopSettings.neutral
        settings[.lensBlurApply] = 1
        settings[.lensBlurAmount] = 100
        try catalog.saveDevelopSettings(settings, for: assetID)
        controller = DevelopController(catalog: catalog, previews: PreviewCache(rootURL: folder.appendingPathComponent("Previews")))
        controller.showMaskOverlay = false
        controller.open(assetID)
        _ = try await frame("open", after: nil) { _ in true }
        try await Task.sleep(for: .seconds(2))
        sharp = Self.rgba(try XCTUnwrap(Self.cg(controller.displayImage)))
    }

    override func tearDown() async throws {
        controller?.isLensBlurring = false
        UserDefaults.standard.set(showsOverlay, forKey: "masks.showOverlay")
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Show Overlay

    func testShowOverlayShowsRedEveryTime() async throws {
        let focus = Self.radialFocus()
        controller.isLensBlurring = true
        _ = try await frame("enter", after: shown()) { self.blurred($0) }
        controller.startLensBlurRefine()
        controller.editedMasks = [focus]
        _ = try await frame("focus area", after: shown()) { self.blurred($0) }

        var failures: [String: Int] = [:]
        // (a) the Focus area, nothing selected
        controller.selectedMaskID = nil
        failures["a: nothing selected"] = try await toggleOverlay(20, centre: true)
        // (b) the area selected
        controller.selectedMaskID = focus.id
        failures["b: area selected"] = try await toggleOverlay(20, centre: true)
        // (c) right after an Amount drag
        var after = 0
        for round in 0..<20 {
            for value in stride(from: 30.0, through: 90.0, by: 10) { controller.set(.lensBlurAmount, to: value + Double(round % 2)) }
            after += try await toggleOverlay(1, centre: true)
        }
        failures["c: after an Amount drag"] = after
        // (e) after Cancel and opening the mode again (the area was cancelled: put it back)
        var reopened = 0
        for _ in 0..<20 {
            controller.isLensBlurring = false
            controller.isLensBlurring = true
            controller.startLensBlurRefine()
            if controller.lensBlurArea(.focus) == nil { controller.editedMasks = [focus] }
            controller.selectedMaskID = nil
            reopened += try await toggleOverlay(1, centre: true)
        }
        failures["e: after Cancel and reopening"] = reopened
        // (d) a Focus area from Select Subject, its matte maybe still on its way
        controller.isLensBlurring = false
        controller.isLensBlurring = true
        controller.startLensBlurRefine()
        controller.addLensBlurPart(.subject, to: .focus, mode: .add)
        controller.selectedMaskID = nil
        failures["d: Select Subject area"] = try await toggleOverlay(20, centre: false)

        for (name, count) in failures.sorted(by: { $0.key < $1.key }) { print("LENSBLUR: overlay \(name): \(count) of 20 failed") }
        XCTAssertEqual(failures.values.reduce(0, +), 0, "Show Overlay didn't show red (or didn't go away): \(failures)")
    }

    /// Turns Show Overlay on and off `times` times: on must bring red within 3 s (in the middle
    /// of the photo when `centre`), off must take it away. Returns how many rounds failed.
    private func toggleOverlay(_ times: Int, centre: Bool) async throws -> Int {
        var failed = 0
        for _ in 0..<times {
            // Off must bring back the blurred photo without red; the photo settles first (no new
            // frame for 0.4 s), so a frame still on its way isn't taken for the overlay's.
            try await settle()
            let before = Self.rgba(try XCTUnwrap(Self.cg(controller.displayImage)))
            let started = Date()
            controller.showMaskOverlay = true
            let on = try? await frame("overlay on", after: nil, timeout: 3, quiet: true) {
                centre ? self.redInCentre($0) : self.redFraction($0) > 0.01
            }
            let onMS = Int(Date().timeIntervalSince(started) * 1000)
            controller.showMaskOverlay = false
            let off = try? await frame("overlay off", after: nil, timeout: 3, quiet: true) {
                !self.redInCentre($0) && self.blurred($0)
            }
            if on == nil || off == nil {
                failed += 1
                if let now = Self.cg(controller.displayImage) {
                    print("LENSBLUR:   off frame: diff to before \(String(format: "%.4f", diff(now, before))), to sharp \(String(format: "%.4f", diff(now, sharp))), red centre \(redInCentre(now)), "
                        + "isLensBlurring \(controller.isLensBlurring) apply \(controller.settings[.lensBlurApply]) work \(controller.lensBlurWork ?? "none") full \(controller.displayImage === controller.fullImage)")
                }
                print("LENSBLUR:   overlay round failed: on \(on == nil ? "never red" : "\(onMS) ms"), off \(off == nil ? "red stayed" : "ok"); "
                    + "mask \(controller.isMasking) scope \(controller.maskScope) selected \(String(describing: controller.selectedMaskID)) areas \(controller.settings.lensBlurAreas.count)")
            }
        }
        return failed
    }

    // MARK: Show Overlay zoomed in

    /// Zoomed in (the view asks for the full-size render), with a Select Subject Focus area (Fine
    /// Edges on, as Refine starts it), as Rosh works: Show Overlay on, Refine Edge set to 0, 50
    /// and 100 (`ATELIER_LENS_BLUR_REFINE=0,50,100` picks others) while the red shows, then Show
    /// Overlay off, timed until the new full-size blurred frame is shown (Rosh, Nov 16, 2026:
    /// minutes after Refine Edge was raised).
    func testZoomedOverlayToggleWithRefineEdge() async throws {
        let refines = (ProcessInfo.processInfo.environment["ATELIER_LENS_BLUR_REFINE"] ?? "0,50,100")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        controller.wantsFullResolution = true
        controller.isLensBlurring = true
        try await fullFrame("zoomed, enter the mode", timeout: 120)
        controller.startLensBlurRefine()
        var previous = controller.fullImage
        controller.addLensBlurPart(.subject, to: .focus, mode: .add)
        try await idle()
        try await fullFrame("zoomed, Select Subject area (Fine Edges \(FineEdges.isInstalled ? "on" : "not downloaded"))",
                            timeout: 300, after: previous)
        try await idle()
        var slowest = 0
        for refine in refines {
            try await settle()
            controller.selectedMaskID = nil
            // The blurred photo already reads a little redder than the sharp one; the overlay much more.
            let blurredRed = redFraction(try XCTUnwrap(Self.cg(controller.displayImage)))
            controller.showMaskOverlay = true
            let overlayFrame = try await frame("overlay on", after: controller.displayImage, timeout: 300) {
                self.redFraction($0) > blurredRed + 0.05
            }
            let overlayRed = redFraction(overlayFrame)
            let focusID = try XCTUnwrap(controller.lensBlurArea(.focus)?.id)
            let edited = Date()
            let unchanged = controller.settings
            // As the Refine Edge slider does: one history step on the area.
            controller.updateMask(focusID, step: "Refine Edge") { mask in
                for part in mask.components.indices {
                    if case .subject(var selection) = mask.components[part].shape {
                        selection.refine = refine
                        mask.components[part].shape = .subject(selection)
                    }
                }
            }
            // Refine Edge 0 on a new area changes nothing: the kept full-size frame is right then.
            let changed = controller.settings != unchanged
            try await settle()
            let redMS = Int(Date().timeIntervalSince(edited) * 1000)
            let runs = FineEdges.runs
            previous = changed ? controller.fullImage : nil
            let off = Date()
            controller.showMaskOverlay = false
            // Until the full-size render is in, the current proxy frame (no red) shows, never an
            // older full-size frame.
            var proxyMS: Int?
            while proxyMS == nil, Date().timeIntervalSince(off) < 5 {
                if let shown = controller.displayImage, let full = controller.fullImage, shown === full, full !== previous { break }
                if let shown = controller.displayImage, previous == nil || shown !== previous, let image = Self.cg(shown),
                   redFraction(image) < (blurredRed + overlayRed) / 2 { proxyMS = Int(Date().timeIntervalSince(off) * 1000) }
                try await Task.sleep(for: .milliseconds(5))
            }
            if let previous { XCTAssertFalse(controller.displayImage === previous, "an older full-size frame showed") }
            let fullMS = try await fullFrame(nil, timeout: 300, since: off, after: previous)
            if changed { XCTAssertLessThan(try XCTUnwrap(proxyMS, "no proxy frame before the full-size one"), 1000,
                                           "the proxy frame took over 1 s after Show Overlay off") }
            print("LENSBLUR: zoomed Refine Edge \(Int(refine)): overlay frame settled in \(redMS) ms; Show Overlay off: "
                + "\(proxyMS.map { "proxy frame in \($0) ms, " } ?? "")full-size frame \(fullMS) ms (Fine Edges runs \(FineEdges.runs - runs))")
            slowest = max(slowest, fullMS)
            // A second toggle with nothing changed shows the kept full-size frame at once.
            controller.showMaskOverlay = true
            _ = try? await frame("overlay on", after: nil, timeout: 30, quiet: true) { self.redFraction($0) > 0.01 }
            let again = Date()
            controller.showMaskOverlay = false
            let againMS = try await fullFrame(nil, timeout: 300, since: again)
            print("LENSBLUR: zoomed Refine Edge \(Int(refine)): toggled again, full-size frame in \(againMS) ms")
            slowest = max(slowest, againMS)
        }
        print("LENSBLUR: zoomed overlay slowest: \(slowest) ms")
        XCTAssertLessThan(slowest, 5000, "zoomed in, Show Overlay off took over 5 s to show the full-size photo")
    }

    // MARK: Memory (AT-077)

    /// A whole Lens Blur session on a real RAW, zoomed in, with the memory the process holds
    /// (Activity Monitor's number) after each step, and where it sits (vmmap's summary) at the
    /// end and after letting go of each part. Rosh, Nov 16, 2026: 16 GB after Lens Blur work.
    /// Prints `LENSBLUR-MEM:` lines; fails only if the session can't run.
    func testMemoryAcrossALensBlurSession() async throws {
        func log(_ step: String) {
            let mb = (RenderMemory.footprint() ?? 0) / 1_048_576
            let status = RenderMemory.shared.status
            let peak = (RenderMemory.peakFootprint() ?? 0) / 1_048_576
            print("LENSBLUR-MEM: \(step): \(mb) MB, peak so far \(peak) MB (cache clears \(status.clears), Fine Edges runs \(FineEdges.runs), "
                + "depth runs \(DepthMap.runs))")
        }
        log("photo open, proxy")
        controller.isLensBlurring = true
        _ = try await frame("enter", after: shown()) { self.blurred($0) }
        try await idle()
        log("Lens Blur open (depth found)")
        controller.wantsFullResolution = true
        try await fullFrame("zoomed", timeout: 120)
        try await idle()
        log("zoomed in, full-size frame")
        for value in stride(from: 40.0, through: 100.0, by: 3) {
            let previous = controller.fullImage
            controller.set(.lensBlurAmount, to: value)
            try await fullFrame("memory: Amount \(Int(value))", timeout: 120, after: previous)
        }
        log("21 Amount edits at full size")
        controller.startLensBlurRefine()
        var previous = controller.fullImage
        controller.addLensBlurPart(.subject, to: .focus, mode: .add)
        try await idle()
        try await fullFrame("memory: Select Subject Focus area", timeout: 300, after: previous)
        try await idle()
        log("Select Subject Focus area (Fine Edges \(FineEdges.active?.name ?? "not downloaded"))")
        for index in 0..<6 {
            previous = controller.fullImage
            controller.addLensBlurPart(.radial, to: .blur, mode: .add)
            controller.finishDrawing(.radial(.init(center: .init(x: 0.1 + 0.12 * Double(index), y: 0.15),
                                                   radiusX: 0.06, radiusY: 0.06)))
            try await fullFrame("memory: Blur area \(index + 1)", timeout: 120, after: previous)
        }
        try await idle()
        log("6 Blur areas drawn")
        for value in stride(from: 94.0, through: 34.0, by: -6) { // Amount is 100 after the first loop
            previous = controller.fullImage
            controller.set(.lensBlurAmount, to: value)
            try await fullFrame("memory: Amount \(Int(value)) with the areas", timeout: 120, after: previous)
        }
        log("11 more Amount edits with the areas")
        Self.vmmap("peak")
        try await Task.sleep(for: .seconds(ModelRunner.idleSeconds + 5))
        log("\(Int(ModelRunner.idleSeconds + 5)) s without a model run (model helpers quit when idle)")
        controller.finishLensBlurRefine()
        controller.flushSave()
        _ = try LensBlurPhoto.save(try XCTUnwrap(assetID), catalog: catalog, importer: Importer(catalog: catalog, previews: nil))
        log("after Save")
        controller.isLensBlurring = false
        try await Task.sleep(for: .seconds(5))
        log("Lens Blur closed (Cancel), 5 s later")
        controller.wantsFullResolution = false
        try await Task.sleep(for: .seconds(5))
        log("back to Fit, 5 s later")
        Self.vmmap("closed, at Fit")
        ModelRunner.stopAll()
        try await Task.sleep(for: .seconds(2))
        log("every model helper quit")
        RenderMemory.shared.clear(because: "test")
        try await Task.sleep(for: .seconds(2))
        log("Core Image cache cleared")
        controller.open(nil)
        try await Task.sleep(for: .seconds(3))
        log("photo closed")
        Self.vmmap("photo closed")
    }

    /// This process's memory by kind (vmmap's summary: IOSurface, IOAccelerator, MALLOC...),
    /// the biggest lines, as `LENSBLUR-VMMAP:` lines.
    private static func vmmap(_ when: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["-summary", "\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { print("LENSBLUR-VMMAP: \(when): vmmap didn't run"); return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        let interesting = ["Physical footprint", "IOSurface", "IOAccelerator", "MALLOC_LARGE", "MALLOC_MEDIUM",
                           "MALLOC_SMALL", "MALLOC_TINY", "CoreImage", "Metal", "VM_ALLOCATE", "TOTAL"]
        for line in lines where interesting.contains(where: { line.contains($0) }) {
            print("LENSBLUR-VMMAP: \(when): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// Waits until nothing works in the background (Fine Edges, Lens Blur's own work) for 1 s.
    private func idle() async throws {
        let started = Date()
        var quietSince = Date()
        while Date().timeIntervalSince(quietSince) < 1, Date().timeIntervalSince(started) < 180 {
            if FineEdges.isWorking || controller.lensBlurWork != nil { quietSince = Date() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits until a full-size render for the current settings (other than `previous`) is what's
    /// shown; its ms.
    @discardableResult
    private func fullFrame(_ what: String?, timeout: Double, since: Date = Date(), after previous: NSImage? = nil) async throws -> Int {
        while Date().timeIntervalSince(since) < timeout {
            if let full = controller.fullImage, full !== previous, controller.displayImage === full {
                let ms = Int(Date().timeIntervalSince(since) * 1000)
                if let what { print("LENSBLUR: \(what): \(ms) ms to the full-size frame") }
                return ms
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("\(what ?? "overlay off"): no full-size frame in \(Int(timeout)) s (full image \(controller.fullImage == nil ? "none" : controller.fullImage === previous ? "unchanged" : "new, not shown"))")
        return Int(timeout * 1000)
    }

    // MARK: Drawn parts while Fine Edges works

    /// A drawn part (a radial Blur area in a corner, away from the subject) added while Fine
    /// Edges is still finding the Focus area's matte draws at once, with Vision's edge, and the
    /// matte replaces that edge when it is in. Fine Edges starts cold (the shared cache emptied).
    func testDrawnPartDrawsWhileFineEdgesWorks() async throws {
        try XCTSkipUnless(FineEdges.isInstalled, "Fine Edges isn't downloaded")
        FineMatteCache.shared.removeAll()
        controller.isLensBlurring = true
        try await timed("enter the mode") { self.blurred($0) }
        controller.startLensBlurRefine()
        controller.addLensBlurPart(.subject, to: .focus, mode: .add)
        let subjectStarted = Date()
        while !FineEdges.isWorking, Date().timeIntervalSince(subjectStarted) < 10 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FineEdges.isWorking, "Fine Edges didn't start")
        try await Task.sleep(for: .milliseconds(500))
        let before = Self.rgba(try XCTUnwrap(Self.cg(controller.displayImage)))
        var shown = controller.displayImage
        // As the Blur area's Radial tool does: the tool, then the drawn ellipse.
        controller.addLensBlurPart(.radial, to: .blur, mode: .add)
        let started = Date()
        controller.finishDrawing(.radial(.init(center: .init(x: 0.12, y: 0.15), radiusX: 0.1, radiusY: 0.1)))
        var firstChange: Int?
        var workingAtFirstChange = false
        while Date().timeIntervalSince(started) < 60 {
            if let now = controller.displayImage, now !== shown, let image = Self.cg(now) {
                shown = now
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let change = diff(image, before)
                print("LENSBLUR: drawn part: frame at \(ms) ms, change \(String(format: "%.4f", change)), Fine Edges \(FineEdges.isWorking ? "working" : "done")")
                if firstChange == nil, change > 0.0001 { firstChange = ms; workingAtFirstChange = FineEdges.isWorking }
            }
            if firstChange != nil, !FineEdges.isWorking, controller.lensBlurWork == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        print("LENSBLUR: drawn part added while Fine Edges works: \(firstChange.map { "\($0) ms" } ?? "NO CHANGE in 60 s")"
            + "\(workingAtFirstChange ? " (before the matte)" : " (after the matte)")")
        let ms = try XCTUnwrap(firstChange, "the drawn part never showed")
        XCTAssertLessThan(ms, 2000, "the drawn part waited for Fine Edges")
    }

    // MARK: Every option

    func testEveryOptionChangesThePhoto() async throws {
        controller.isLensBlurring = true
        try await timed("enter the mode") { self.blurred($0) }
        try await change("Apply off", { self.controller.setLensBlurApplied(false) }) { self.diff($0, self.sharp) < 0.002 }
        try await change("Apply on", { self.controller.setLensBlurApplied(true) }) { self.blurred($0) }
        try await change("Blur Amount 100 → 30") { self.controller.set(.lensBlurAmount, to: 30) }
        try await change("Blur Amount 30 → 100") { self.controller.set(.lensBlurAmount, to: 100) }
        for shape in 1...4 { try await change("Bokeh \(shape)", minimum: 0.0002) { self.controller.set(.lensBlurBokeh, to: Double(shape)) } }
        try await change("Bokeh 0", minimum: 0.0002) { self.controller.set(.lensBlurBokeh, to: 0) }
        try await change("Cat Eye 0 → 100", minimum: 0.0002) { self.controller.set(.lensBlurCatEye, to: 100) }
        try await change("Boost 50 → 100", minimum: 0.0002) { self.controller.set(.lensBlurBoost, to: 100) }
        try await change("Focal Range Far 20 → 70") { self.controller.set(.lensBlurFocusFar, to: 70) }
        try await change("Focal Range Near 0 → 40", minimum: 0.0003) { self.controller.set(.lensBlurFocusNear, to: 40) }

        // The focus picker, then a render asked for while it works: how long renders wait.
        try await settingsChange("focus picker (centre)") {
            self.controller.picker = .lensFocus
            self.controller.pickLensFocus(at: CGPoint(x: 0.5, y: 0.5))
        }
        controller.picker = nil
        try await renderStall("focus picker") { self.controller.pickLensFocus(at: CGPoint(x: 0.3, y: 0.6)) }
        // Subject: the first time on a photo it finds the subject too; a render waits meanwhile?
        try await renderStall("Subject (first time)") { self.controller.focusLensBlurOnSubject() }
        controller.set(.lensBlurFocusNear, to: 5)
        controller.set(.lensBlurFocusFar, to: 10)
        try await settingsChange("Subject (again)") { self.controller.focusLensBlurOnSubject() }
        print("LENSBLUR: Subject message: \(controller.lensBlurMessage ?? "none")")

        try await change("Visualize Depth on", { self.controller.visualizesDepth = true }) { self.diff($0, self.sharp) > 0.05 }
        try await change("Visualize Depth off", { self.controller.visualizesDepth = false }) { self.blurredOrFocused($0) }
        // A strong blur (focus on the nearest tenth) for Before, Refine and Save.
        controller.set(.lensBlurFocusNear, to: 0)
        controller.set(.lensBlurFocusFar, to: 10)
        controller.set(.lensBlurAmount, to: 100)
        try await settle()
        print("LENSBLUR: strong blur: \(String(format: "%.4f", diff(try XCTUnwrap(Self.cg(controller.displayImage)), sharp))) from the photo")
        try await change("Before on", { self.controller.showingBefore = true }) { self.diff($0, self.sharp) < 0.002 }
        try await change("Before off", { self.controller.showingBefore = false }) { self.diff($0, self.sharp) > 0.004 }

        controller.flushSave()
        var started = Date()
        _ = try LensBlurPhoto.save(try XCTUnwrap(assetID), catalog: catalog, importer: Importer(catalog: catalog, previews: nil))
        print("LENSBLUR: Save without Refine areas: \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        controller.startLensBlurRefine()
        try await change("Refine: Select Subject added to Focus", minimum: 0.0003) {
            self.controller.addLensBlurPart(.subject, to: .focus, mode: .add)
        }
        try await settle()
        // Through the Radial tool, as the panel does (setting `editedMasks` alone asks for no
        // render: the frame that came 23 s later was Fine Edges' matte arriving).
        try await change("Refine: radial part added to Blur", minimum: 0.0001) {
            self.controller.addLensBlurPart(.radial, to: .blur, mode: .add)
            self.controller.finishDrawing(.radial(.init(center: .init(x: 0.12, y: 0.15), radiusX: 0.1, radiusY: 0.1)))
        }
        controller.finishLensBlurRefine()

        // Save: the TIFF in the catalog, next to the copied RAW.
        // The editor's Fine Edges matte in first (Save then reuses it).
        let matteWait = Date()
        while FineEdges.isWorking, Date().timeIntervalSince(matteWait) < 90 { try await Task.sleep(for: .milliseconds(50)) }
        try await settle()
        controller.flushSave()
        let runsBefore = FineEdges.runs
        started = Date()
        let saved = try LensBlurPhoto.save(try XCTUnwrap(assetID), catalog: catalog, importer: Importer(catalog: catalog, previews: nil))
        print("LENSBLUR: Save with Refine areas: \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(saved.url.lastPathComponent), new \(saved.isNew), "
            + "Fine Edges runs during it: \(FineEdges.runs - runsBefore)")
        XCTAssertEqual(FineEdges.runs - runsBefore, 0, "Save reuses the editor's Fine Edges matte")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path), "Save wrote no TIFF")
        XCTAssertEqual(saved.url.pathExtension.lowercased(), "tif")

        // Cancel puts every value back (the Save above was not kept, so this cancels it all).
        let entry = DevelopSettings.neutral
        controller.isLensBlurring = false
        for parameter in [DevelopSettings.Parameter.lensBlurAmount, .lensBlurBokeh, .lensBlurCatEye, .lensBlurBoost,
                          .lensBlurFocusNear, .lensBlurFocusFar] {
            XCTAssertEqual(controller.settings[parameter], parameter == .lensBlurAmount ? 100 : entry[parameter],
                           "Cancel restores \(parameter)")
        }
        XCTAssertTrue(controller.settings.lensBlurAreas.isEmpty, "Cancel removes the areas")
        XCTAssertEqual(try catalog.developSettings(for: try XCTUnwrap(assetID)), controller.settings, "and saves that")
    }

    // MARK: Fine Edges

    /// Select Subject with Fine Edges as a Focus area: how long until its frame, with Fine Edges
    /// on the CPU or, with `ATELIER_FINE_EDGES_COREML=1`, Core ML.
    func testFineEdgesTime() async throws {
        try XCTSkipUnless(FineEdges.isInstalled, "Fine Edges isn't downloaded")
        FineEdges.prefersCoreML = ProcessInfo.processInfo.environment["ATELIER_FINE_EDGES_COREML"] != nil
        controller.isLensBlurring = true
        try await timed("enter the mode") { self.blurred($0) }
        controller.startLensBlurRefine()
        let started = Date()
        controller.addLensBlurPart(.subject, to: .focus, mode: .add)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, FineEdges.isWorking || controller.lensBlurWork != nil || Date().timeIntervalSince(started) < 0.3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        print("LENSBLUR: Fine Edges (\(FineEdges.prefersCoreML ? "Core ML ALL" : "CPU"), \(FineEdges.active?.name ?? "?")): "
            + "\(Int(Date().timeIntervalSince(started) * 1000)) ms until nothing works")
    }

    // MARK: Helpers

    private static func radialFocus() -> DevelopSettings.Mask {
        var focus = DevelopSettings.Mask(name: "Focus", components: [.init(.radial(.init(center: .init(x: 0.5, y: 0.5),
                                                                                         radiusX: 0.12, radiusY: 0.12)))])
        focus.lensBlurRole = .focus
        return focus
    }

    private func shown() -> NSImage? { controller.displayImage }

    /// Waits until no new frame has come for 0.4 s (at most 10 s).
    private func settle() async throws {
        var last = controller.displayImage
        var quietSince = Date()
        let started = Date()
        while Date().timeIntervalSince(quietSince) < 0.4, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(10))
            if controller.displayImage !== last { last = controller.displayImage; quietSince = Date() }
        }
    }

    /// `action`, then the time until a frame that differs from the one before by `minimum`.
    private func change(_ what: String, minimum: Double = 0.002, _ action: () -> Void,
                        until matches: ((CGImage) -> Bool)? = nil) async throws {
        let before = Self.rgba(try XCTUnwrap(Self.cg(controller.displayImage)))
        let started = Date()
        action()
        let found = try? await frame(what, after: nil, timeout: 30, quiet: true) {
            matches?($0) ?? (self.diff($0, before) >= minimum)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let changed = found.map { diff($0, before) } ?? 0
        print("LENSBLUR: \(what): \(found == nil ? "NO CHANGE in 30 s" : "\(ms) ms")\(ms > 300 && found != nil ? " (over 300 ms)" : ""), change \(String(format: "%.4f", changed))")
        XCTAssertNotNil(found, "\(what) didn't change the photo")
    }

    private func timed(_ what: String, matches: @escaping (CGImage) -> Bool) async throws {
        let started = Date()
        _ = try await frame(what, after: nil, timeout: 20, quiet: true, matches: matches)
        print("LENSBLUR: \(what): \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    /// `action`, then the time until the Focal Range changes (a picker or Subject result).
    private func settingsChange(_ what: String, _ action: () -> Void) async throws {
        let before = (controller.settings[.lensBlurFocusNear], controller.settings[.lensBlurFocusFar])
        let started = Date()
        action()
        while Date().timeIntervalSince(started) < 20 {
            let now = (controller.settings[.lensBlurFocusNear], controller.settings[.lensBlurFocusFar])
            if now != before {
                print("LENSBLUR: \(what): Focal Range \(Int(before.0))–\(Int(before.1)) → \(Int(now.0))–\(Int(now.1)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                return
            }
            if let message = controller.lensBlurMessage ?? controller.pickerMessage, Date().timeIntervalSince(started) > 0.2 {
                print("LENSBLUR: \(what): no change, message \"\(message)\" after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        print("LENSBLUR: \(what): NO CHANGE in 20 s")
    }

    /// Starts `action`, asks at once for an Amount change, and times that change's frame: how
    /// long renders wait behind the action.
    private func renderStall(_ what: String, _ action: () -> Void) async throws {
        let before = Self.rgba(try XCTUnwrap(Self.cg(controller.displayImage)))
        action()
        let started = Date()
        controller.set(.lensBlurAmount, to: controller.settings[.lensBlurAmount] > 60 ? 40 : 90)
        let found = try? await frame("\(what) stall", after: nil, timeout: 20, quiet: true) { self.diff($0, before) > 0.002 }
        print("LENSBLUR: render during \(what): \(found == nil ? "none in 20 s" : "\(Int(Date().timeIntervalSince(started) * 1000)) ms") to an Amount change's frame")
        try await Task.sleep(for: .seconds(2))
    }

    private func blurred(_ image: CGImage) -> Bool { diff(image, sharp) > 0.004 }
    private func blurredOrFocused(_ image: CGImage) -> Bool { diff(image, sharp) < 0.05 }

    /// Waits for a frame on screen that `matches`.
    @discardableResult
    private func frame(_ what: String, after previous: NSImage?, timeout: Double = 15, quiet: Bool = false,
                       matches: (CGImage) -> Bool) async throws -> CGImage {
        let started = Date()
        var last: NSImage?
        while Date().timeIntervalSince(started) < timeout {
            if let shown = controller.displayImage, shown !== previous, shown !== last, let image = Self.cg(shown) {
                last = shown
                if matches(image) { return image }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if !quiet { XCTFail("\(what): no matching frame in \(timeout) s") }
        throw CancellationError()
    }

    /// Mean difference of the grey levels, 0...1.
    private func diff(_ image: CGImage, _ reference: [UInt8]) -> Double {
        let pixels = Self.rgba(image)
        guard pixels.count == reference.count, !pixels.isEmpty else { return 1 }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let a = (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 3
            let b = (Double(reference[index]) + Double(reference[index + 1]) + Double(reference[index + 2])) / 3
            total += abs(a - b)
        }
        return total / Double(pixels.count / 4) / 255
    }

    /// The share of pixels clearly redder than in the unblurred photo.
    private func redFraction(_ image: CGImage) -> Double {
        let pixels = Self.rgba(image)
        guard pixels.count == sharp.count else { return 0 }
        var red = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where Self.redness(pixels, index) - Self.redness(sharp, index) > 25 { red += 1 }
        return Double(red) / Double(pixels.count / 4)
    }

    /// The middle of the photo (inside the radial Focus area) is red-tinted: r clearly above g
    /// and b, and redder than the photo itself.
    private func redInCentre(_ image: CGImage) -> Bool {
        let pixels = Self.rgba(image)
        guard pixels.count == sharp.count else { return false }
        let width = 256, height = pixels.count / 4 / width
        let index = ((height / 2) * width + width / 2) * 4
        let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
        return r > g + 20 && r > b + 20 && Self.redness(pixels, index) - Self.redness(sharp, index) > 25
    }

    private static func redness(_ pixels: [UInt8], _ index: Int) -> Double {
        Double(pixels[index]) - (Double(pixels[index + 1]) + Double(pixels[index + 2])) / 2
    }

    static func cg(_ image: NSImage?) -> CGImage? { image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }

    /// A 256 px wide RGBA thumbnail.
    static func rgba(_ image: CGImage) -> [UInt8] {
        let width = 256, height = max(1, Int(Double(image.height) / Double(image.width) * 256))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
}

/// Saved Lens Blur settings cost nothing outside the Lens Blur mode (Rosh, Nov 16, 2026: does a
/// photo with Lens Blur on slow Develop down?). The same RAW opens in Develop, not in the mode,
/// with no Lens Blur (A) and with every Lens Blur setting (B: Apply, Amount 80, a Focal Range, a
/// Select Subject Focus area with Fine Edges and Refine Edge 50, a radial Blur area), in turns.
/// Each time: open to the first frame, Exposure and Contrast drags at fit and zoomed to 100%, the
/// full-size render after the zoomed drag and the stored preview write. B must run no depth model,
/// Fine Edges, Vision subject or Lens Blur, and its frames must be A's. Opt-in like the class
/// above: `ATELIER_LENS_BLUR_RAW=/path/to/photo.NEF`; `ATELIER_LENS_BLUR_ROUNDS` (default 2) A/B
/// turns. Times are printed as `LENSBLUR-AB:` lines.
@MainActor
final class LensBlurOutsideModeTests: XCTestCase {
    private var folder: URL!
    private var catalog: Catalog!
    private var assetID: Int64!
    private var pressed = false

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["ATELIER_LENS_BLUR_RAW"] else {
            throw XCTSkip("Set ATELIER_LENS_BLUR_RAW to a RAW file to run")
        }
        try XCTSkipUnless(DepthMap.isInstalled, "The depth model isn't downloaded")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LensBlurAB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = folder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: raw)
        catalog = try Catalog()
        let result = await Importer(catalog: catalog, previews: nil).run(sources: [raw], options: ImportOptions(buildPreviews: false))
        assetID = try XCTUnwrap(result.importedAssetIDs.first)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// B's settings: everything the Lens Blur panel and its Refine can store.
    static func lensBlurSettings() -> DevelopSettings {
        var settings = DevelopSettings.neutral
        settings[.lensBlurApply] = 1
        settings[.lensBlurAmount] = 80
        settings[.lensBlurFocusNear] = 10
        settings[.lensBlurFocusFar] = 35
        var focus = DevelopSettings.Mask(name: "Focus", components: [
            .init(.subject(DevelopSettings.Selection(feather: 3, refine: 50, fineEdges: true)))])
        focus.lensBlurRole = .focus
        var blur = DevelopSettings.Mask(name: "Blur", components: [
            .init(.radial(.init(center: .init(x: 0.12, y: 0.15), radiusX: 0.1, radiusY: 0.1)))])
        blur.lensBlurRole = .blur
        settings.lensBlurAreas = [focus, blur]
        return settings
    }

    struct Run {
        var openMS = 0.0
        var fit: [Double] = []
        var zoomed: [Double] = []
        var fullMS = 0.0
        var previewMS = 0.0
        var fitFrame: CGImage?
        var fullFrame: CGImage?
        var previews: [String: Data] = [:]
    }

    struct Work: Equatable {
        var depth = 0, fineEdges = 0, subject = 0, lensBlur = 0
        static func now() -> Work {
            Work(depth: DepthMap.runs, fineEdges: FineEdges.runs, subject: AIImaging.subjectRuns.withLock { $0 },
                 lensBlur: LensBlur.applyRuns.withLock { $0 })
        }
        static func - (a: Work, b: Work) -> Work {
            Work(depth: a.depth - b.depth, fineEdges: a.fineEdges - b.fineEdges, subject: a.subject - b.subject,
                 lensBlur: a.lensBlur - b.lensBlur)
        }
    }

    func testLensBlurSettingsCostNothingOutsideTheMode() async throws {
        let rounds = Int(ProcessInfo.processInfo.environment["ATELIER_LENS_BLUR_ROUNDS"] ?? "") ?? 2
        // A first, untimed: the RAW's decode and Core Image's programs, for both.
        _ = try await run(lensBlur: false, name: "warm")
        var a: [Run] = [], b: [Run] = []
        var sawWork = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if DepthMap.isWorking || FineEdges.isWorking { sawWork = true }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { watcher.cancel() }
        for round in 1...rounds {
            a.append(try await run(lensBlur: false, name: "A\(round)"))
            let before = Work.now()
            sawWork = false
            b.append(try await run(lensBlur: true, name: "B\(round)"))
            let work = Work.now() - before
            print("LENSBLUR-AB: B\(round) Lens Blur work outside the mode: depth \(work.depth), Fine Edges \(work.fineEdges), "
                + "Vision subject \(work.subject), LensBlur.apply \(work.lensBlur), work flags \(sawWork ? "SEEN" : "never")")
            XCTAssertEqual(work, Work(), "B ran Lens Blur work outside the mode")
            XCTAssertFalse(sawWork, "the depth model or Fine Edges worked outside the mode")
        }

        // The same pictures: B's frames and stored previews are A's.
        for (x, y) in zip(a, b) {
            XCTAssertTrue(Self.same(x.fitFrame, y.fitFrame), "B's fit frame differs from A's")
            XCTAssertTrue(Self.same(x.fullFrame, y.fullFrame), "B's full-size frame differs from A's")
            XCTAssertFalse(x.previews.isEmpty, "no stored previews")
            XCTAssertEqual(x.previews, y.previews, "B's stored previews differ from A's")
        }

        func row(_ what: String, _ value: (Run) -> Double) -> (Double, Double) {
            let av = Self.median(a.map(value)), bv = Self.median(b.map(value))
            print("LENSBLUR-AB: | \(what) | \(Self.ms(av)) | \(Self.ms(bv)) | \(String(format: "%+.1f%%", (bv - av) / max(av, 0.001) * 100)) |")
            return (av, bv)
        }
        print("LENSBLUR-AB: | step | A (no Lens Blur) | B (Lens Blur saved) | B vs A |")
        _ = row("open → first frame", { $0.openMS })
        let fitMedian = row("fit drag, median frame", { Self.median($0.fit) })
        _ = row("fit drag, p95 frame", { Self.p95($0.fit) })
        let zoomedMedian = row("100% drag, median frame", { Self.median($0.zoomed) })
        _ = row("100% drag, p95 frame", { Self.p95($0.zoomed) })
        _ = row("full-size render after the drag", { $0.fullMS })
        _ = row("stored preview write", { $0.previewMS })
        // Frame times swing by a few ms run to run; a real cost shows well past that.
        XCTAssertLessThan(fitMedian.1, fitMedian.0 * 1.15 + 3, "B's fit drag frames are slower")
        XCTAssertLessThan(zoomedMedian.1, zoomedMedian.0 * 1.15 + 3, "B's zoomed drag frames are slower")
    }

    /// One open of the photo with A's or B's settings, timed.
    private func run(lensBlur: Bool, name: String) async throws -> Run {
        var settings = lensBlur ? Self.lensBlurSettings() : DevelopSettings.neutral
        settings[.exposure] = 0
        try catalog.saveDevelopSettings(settings, for: assetID)
        let previewsFolder = folder.appendingPathComponent("Previews-\(name)")
        let controller = DevelopController(catalog: catalog, previews: PreviewCache(rootURL: previewsFolder),
                                           isPrimaryButtonPressed: { [unowned self] in self.pressed })
        controller.showMaskOverlay = false
        var result = Run()
        var started = Date()
        controller.open(assetID)
        while controller.image == nil || controller.isLoading || controller.showsStandIn {
            guard Date().timeIntervalSince(started) < 60 else { XCTFail("\(name): no first frame"); return result }
            try await Task.sleep(for: .milliseconds(2))
        }
        result.openMS = Self.ms(since: started)
        XCTAssertFalse(controller.isLensBlurring)
        // The warm-up, the first-open preview and the neighbours' preload finish first.
        try await Task.sleep(for: .seconds(3))

        // At fit.
        result.fit = try await drag(controller, from: 0, to: 0.6)
        try await settle(controller)
        result.fitFrame = Self.cg(controller.displayImage)
        // The stored preview: written when the drag ends (mouse up).
        var stored = false
        controller.onPreviewsUpdated = { _ in stored = true }
        started = Date()
        pressed = false
        controller.endPointerEdit()
        while !stored {
            guard Date().timeIntervalSince(started) < 30 else { XCTFail("\(name): no preview stored"); break }
            try await Task.sleep(for: .milliseconds(2))
        }
        result.previewMS = Self.ms(since: started)
        controller.onPreviewsUpdated = nil

        // Zoomed to 100%: the full-size render of the photo first, then the drag.
        controller.wantsFullResolution = true
        try await fullFrame(controller, after: nil, name: "\(name) zoom in")
        result.zoomed = try await drag(controller, from: 0.6, to: 0.2)
        let previous = controller.fullImage
        started = Date()
        pressed = false
        controller.endPointerEdit()
        try await fullFrame(controller, after: previous, name: "\(name) after the drag")
        result.fullMS = Self.ms(since: started)
        result.fullFrame = Self.cg(controller.fullImage)
        // The preview queue's write after the zoomed drag, then read what was stored.
        try await Task.sleep(for: .seconds(2))
        result.previews = Self.files(in: previewsFolder)
        controller.open(nil)
        print("LENSBLUR-AB: \(name): open \(Self.ms(result.openMS)), fit median \(Self.ms(Self.median(result.fit))) "
            + "p95 \(Self.ms(Self.p95(result.fit))), 100% median \(Self.ms(Self.median(result.zoomed))) p95 \(Self.ms(Self.p95(result.zoomed))), "
            + "full-size \(Self.ms(result.fullMS)), preview \(Self.ms(result.previewMS)), \(result.previews.count) preview files")
        return result
    }

    /// An Exposure drag (`from` to `to`, 20 steps) and a Contrast drag (0 to 40 or back, 20
    /// steps), the mouse held down throughout: each step's time to its frame on screen.
    private func drag(_ controller: DevelopController, from: Double, to: Double) async throws -> [Double] {
        pressed = true
        controller.beginPointerEdit()
        var times: [Double] = []
        let contrastStart = controller.settings[.contrast]
        let contrastEnd = contrastStart > 20 ? 0.0 : 40
        let steps = 20
        for step in 1...steps {
            times.append(try await frameAfter(controller) { controller.set(.exposure, to: from + (to - from) * Double(step) / Double(steps)) })
        }
        for step in 1...steps {
            let value = contrastStart + (contrastEnd - contrastStart) * Double(step) / Double(steps)
            times.append(try await frameAfter(controller) { controller.set(.contrast, to: value) })
        }
        return times
    }

    /// `change`, then the ms until a new rendered frame is shown.
    private func frameAfter(_ controller: DevelopController, _ change: () -> Void) async throws -> Double {
        let previous = controller.image
        let started = Date()
        change()
        while controller.image === previous {
            guard Date().timeIntervalSince(started) < 20 else { XCTFail("no frame in 20 s"); break }
            try await Task.sleep(for: .microseconds(500))
        }
        return Self.ms(since: started)
    }

    private func fullFrame(_ controller: DevelopController, after previous: NSImage?, name: String) async throws {
        let started = Date()
        while true {
            if let full = controller.fullImage, full !== previous, controller.displayImage === full { return }
            guard Date().timeIntervalSince(started) < 120 else { XCTFail("\(name): no full-size frame in 120 s"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func settle(_ controller: DevelopController) async throws {
        var last = controller.image
        var quietSince = Date()
        let started = Date()
        while Date().timeIntervalSince(quietSince) < 0.5, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(10))
            if controller.image !== last { last = controller.image; quietSince = Date() }
        }
    }

    private static func files(in folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url), !url.hasDirectoryPath {
                // By the path inside the folder (the folder's own path may resolve through /private).
                found[url.resolvingSymlinksInPath().path.replacingOccurrences(
                    of: folder.resolvingSymlinksInPath().path + "/", with: "")] = data
            }
        }
        return found
    }

    /// The same pixels, bit for bit.
    private static func same(_ a: CGImage?, _ b: CGImage?) -> Bool {
        guard let a, let b, a.width == b.width, a.height == b.height,
              let x = a.dataProvider?.data, let y = b.dataProvider?.data else { return false }
        return (x as Data) == (y as Data)
    }

    private static func cg(_ image: NSImage?) -> CGImage? { LensBlurRealPhotoTests.cg(image) }
    private static func ms(since date: Date) -> Double { Date().timeIntervalSince(date) * 1000 }
    private static func ms(_ value: Double) -> String { String(format: "%.1f ms", value) }
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    private static func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
    }
}
