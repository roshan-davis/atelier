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
        XCTFail("\(what ?? "overlay off"): no full-size frame in \(Int(timeout)) s")
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
