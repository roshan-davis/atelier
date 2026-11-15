import AgentActions
import AgentMCP
import AtelierActions
import AtelierCore
import CoreGraphics
import Foundation
import ImageIO

/// An agent's auto or match_look while it measures photos: the status bar shows it with Cancel.
struct AgentJob {
    let id: UUID
    let cancel: () -> Void
}

/// The rest of AT-050d's Edit tools. crop and add_mask change settings at once, like adjust;
/// auto and match_look first measure the photos in the background (with progress and Cancel in
/// the status bar), then make their change through the same guard on the main thread. Each call
/// is one step in each photo's Develop history named for the app, which undo_change undoes.
extension AgentServer {
    // MARK: crop

    func crop(_ parameters: CropParameters, _ client: AgentClient, _ model: LibraryModel) throws -> MCPToolResult {
        let plan: CropRules.Plan
        switch CropRules.plan(parameters) {
        case .failure(let problems): throw ArgumentProblem(problems.text)
        case .success(let value): plan = value
        }
        return try write(parameters, title: plan.title, client, model, kind: .develop) { named, _ in
            let current = try model.develop.currentSettings(for: named)
            var updated: [Int64: DevelopSettings] = [:]
            for id in named {
                guard var settings = current[id] else { continue }
                let size = try uprightSize(of: id, model)
                let crop = Self.cropped(settings.crop ?? DevelopSettings.Crop(), plan,
                                        uprightAspect: Double(size.width / size.height))
                settings.crop = crop.isIdentity ? nil : crop
                updated[id] = settings
            }
            try model.develop.apply(each: updated, step: "\(plan.title) (\(client.name))")
        }
    }

    /// The crop tool's own steps, in the order reset, rotate, flip, straighten, aspect and
    /// orientation, box. Constrain Crop then fits the open photo's crop, as after a drag; other
    /// photos are fitted when they're opened in Develop.
    static func cropped(_ start: DevelopSettings.Crop, _ plan: CropRules.Plan, uprightAspect: Double) -> DevelopSettings.Crop {
        var crop = plan.reset ? DevelopSettings.Crop() : start
        if let rotate = plan.rotate { crop = crop.turned(clockwise: rotate == .right) }
        if let flip = plan.flip { crop = crop.flipped(horizontally: flip == .horizontal) }
        // The turned photo's width / height, which crop fractions are measured against.
        let aspect = crop.quarterTurns % 2 == 1 ? 1 / uprightAspect : uprightAspect
        if let angle = plan.angle {
            crop.angle = min(45, max(-45, angle))
            crop = crop.fitted(imageAspect: aspect)
        }
        if let choice = plan.aspect {
            switch choice {
            case .free:
                crop.lockedAspect = nil
            case .original, .ratio:
                let landscape = choice.landscape ?? max(aspect, 1 / aspect)
                let isPortrait: Bool
                if let orientation = plan.orientation {
                    isPortrait = orientation == .portrait
                } else if choice == .original {
                    isPortrait = aspect < 1
                } else {
                    isPortrait = crop.width * aspect < crop.height
                }
                crop = Self.locked(crop, to: isPortrait ? 1 / landscape : landscape, imageAspect: aspect)
            }
        } else if let orientation = plan.orientation {
            let isPortrait = crop.width * aspect < crop.height
            if isPortrait != (orientation == .portrait) { crop = crop.switchedOrientation(imageAspect: aspect) }
        }
        if let box = plan.box {
            crop.x = box[0]
            crop.y = box[1]
            crop.width = box[2]
            crop.height = box[3]
            crop.lockedAspect = nil
            crop = crop.fitted(imageAspect: aspect)
        }
        return crop
    }

    /// The largest crop of `ratio` (width / height, either way up) around the crop's center that
    /// stays on the photo, as choosing an aspect in the crop tool does.
    static func locked(_ crop: DevelopSettings.Crop, to ratio: Double, imageAspect: Double) -> DevelopSettings.Crop {
        var copy = crop
        copy.lockedAspect = ratio
        let size = DevelopSettings.Crop.centered(aspect: ratio, imageAspect: imageAspect)
        let cx = crop.x + crop.width / 2, cy = crop.y + crop.height / 2
        copy.width = size.width
        copy.height = size.height
        copy.x = min(max(0, cx - size.width / 2), 1 - size.width)
        copy.y = min(max(0, cy - size.height / 2), 1 - size.height)
        return copy.fitted(imageAspect: imageAspect)
    }

    /// A photo's upright, uncropped size (only its shape matters): the open photo's as decoded,
    /// another's from the catalog or, failing that, its file's header.
    func uprightSize(of id: Int64, _ model: LibraryModel) throws -> CGSize {
        if model.develop.assetID == id, let size = model.develop.sourceSize, size.width > 0, size.height > 0 {
            return size
        }
        let detail = try model.catalog.detail(for: id)
        var width = detail?.asset.width, height = detail?.asset.height
        var orientation = detail?.asset.orientation
        if width == nil || height == nil, let url = detail?.fileURL,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int
            height = properties[kCGImagePropertyPixelHeight] as? Int
            orientation = properties[kCGImagePropertyOrientation] as? Int
        }
        guard let width, let height, width > 0, height > 0 else {
            throw ArgumentProblem("Photo \(id)'s size isn't known and its original is offline. Nothing was changed.")
        }
        // EXIF orientations 5 to 8 are a quarter turn.
        let turned = (5...8).contains(orientation ?? 1)
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    // MARK: add_mask

    /// Every mask slider by its agent name ("exposure").
    static let maskSliders: [String: DevelopSettings.LocalParameter] = Dictionary(
        uniqueKeysWithValues: DevelopSettings.LocalParameter.allCases.map { (AdjustRules.snakeName($0.rawValue), $0) })

    /// The mask's own Color Grading by agent name ("grade_shadows_hue", "grade_blending").
    static let maskGrades: [String: DevelopSettings.Parameter] = Dictionary(
        uniqueKeysWithValues: DevelopSettings.Panel.colorGrading.parameters.map { (AdjustRules.snakeName($0.rawValue), $0) })

    /// Every name `add_mask` settings take, with its range.
    static var maskSettingRanges: [String: ClosedRange<Double>] {
        var ranges = maskSliders.mapValues(\.range)
        for (name, parameter) in maskGrades { ranges[name] = parameter.range }
        return ranges
    }

    func addMask(_ parameters: AddMaskParameters, _ client: AgentClient, _ model: LibraryModel) throws -> MCPToolResult {
        let plan: MaskRules.Plan
        switch MaskRules.plan(parameters, sliders: Self.maskSettingRanges) {
        case .failure(let problems): throw ArgumentProblem(problems.text)
        case .success(let value): plan = value
        }
        var names: [Int64: String] = [:]
        let result = try write(parameters, title: plan.title, client, model, kind: .develop) { named, _ in
            let current = try model.develop.currentSettings(for: named)
            var updated: [Int64: DevelopSettings] = [:]
            for id in named {
                guard var settings = current[id] else { continue }
                let space = Self.maskSpace(settings, size: try uprightSize(of: id, model))
                var component = DevelopSettings.MaskComponent(Self.shape(plan, in: space))
                if let wanted = plan.toMask {
                    guard let index = settings.masks.firstIndex(where: {
                        $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    }) else {
                        let have = settings.masks.map { "“\($0.name)”" }.joined(separator: ", ")
                        throw ArgumentProblem("Photo \(id) has no mask “\(wanted)”"
                                              + (have.isEmpty ? " (it has none)." : "; it has \(have).")
                                              + " Nothing was changed.")
                    }
                    component.mode = DevelopSettings.MaskComponent.Mode(rawValue: plan.combine.rawValue) ?? .add
                    component.inverted = plan.invert
                    settings.masks[index].components.append(component)
                    names[id] = settings.masks[index].name
                } else {
                    var mask = DevelopSettings.Mask(name: plan.name ?? settings.nextMaskName(), components: [component])
                    mask.inverted = plan.invert
                    if let amount = plan.amount { mask.amount = amount }
                    for setting in plan.settings {
                        if let parameter = Self.maskSliders[setting.name] {
                            mask[parameter] = setting.value
                        } else if let parameter = Self.maskGrades[setting.name] {
                            mask[grade: parameter] = setting.value
                        }
                    }
                    settings.masks.append(mask)
                    names[id] = mask.name
                }
                updated[id] = settings
            }
            try model.develop.apply(each: updated, step: "\(plan.title) (\(client.name))")
        }
        var members: [String: JSONValue] = [:]
        let distinct = Set(names.values)
        if distinct.count == 1, let name = distinct.first { members["mask"] = .string(name) }
        if [AgentMaskKind.subject, .background, .object, .people].contains(plan.kind) {
            members["note"] = .string("Atelier finds the \(plan.kind == .people ? "people" : "subject") when the photo "
                                      + "renders. Check with get_preview; the person can refine it in Masking.")
        }
        return adding(members, to: result)
    }

    /// Maps the agent's coordinates (fractions of the photo as shown, cropped) to the mask's (the
    /// upright, uncropped photo), the way Masking maps a drag on the photo.
    static func maskSpace(_ settings: DevelopSettings, size: CGSize) -> MaskSpace {
        let crop = settings.crop ?? DevelopSettings.Crop()
        let output = crop.outputSize(size)
        return MaskSpace(sourceSize: size, crop: crop, rect: CGRect(origin: .zero, size: output), outputSize: output)
    }

    static func shape(_ plan: MaskRules.Plan, in space: MaskSpace) -> DevelopSettings.MaskComponent.Shape {
        let width = space.outputSize.width, height = space.outputSize.height
        func view(_ point: [Double]) -> CGPoint { CGPoint(x: CGFloat(point[0]) * width, y: CGFloat(point[1]) * height) }
        switch plan.kind {
        case .subject:
            return .subject(DevelopSettings.Selection(feather: plan.feather ?? 20, refine: plan.refine, grow: plan.grow))
        case .background:
            return .subject(DevelopSettings.Selection(feather: plan.feather ?? 20, refine: plan.refine, grow: plan.grow,
                                                      background: true))
        case .object:
            let box = plan.box ?? [0.3, 0.3, 0.4, 0.4]
            let rect = DevelopSettings.MaskRect(space.maskPoint(view([box[0], box[1]])),
                                                space.maskPoint(view([box[0] + box[2], box[1] + box[3]])))
            return .subject(DevelopSettings.Selection(box: rect, feather: plan.feather ?? 20, refine: plan.refine,
                                                      grow: plan.grow))
        case .people:
            let parts = plan.parts.compactMap(\.part)
            return .people(DevelopSettings.PeopleSelection(person: plan.person, parts: parts, feather: plan.feather ?? 10,
                                                           refine: plan.refine, grow: plan.grow))
        case .linear:
            return .linear(DevelopSettings.LinearGradient(start: space.maskPoint(view(plan.start)),
                                                          end: space.maskPoint(view(plan.end))))
        case .radial:
            return .radial(space.radial(center: view(plan.center), width: CGFloat(plan.size[0]) * width,
                                        height: CGFloat(plan.size[1]) * height, feather: plan.feather ?? 50))
        case .luminance:
            return .luminance(DevelopSettings.LuminanceRange(low: plan.range[0], high: plan.range[1],
                                                             smoothness: plan.smoothness))
        }
    }

    // MARK: auto and match_look: measured in the background

    /// One photo as it was when a measuring tool started.
    struct MeasuredPhoto: Sendable {
        let id: Int64
        let url: URL
        let settings: DevelopSettings
    }

    /// What a measuring tool found: each photo's new settings, the photos it couldn't measure,
    /// and anything to tell the agent.
    struct Measurement: Sendable {
        var settings: [Int64: DevelopSettings] = [:]
        var failed: [Int64] = []
        var notes: [String] = []
    }

    typealias Measure = @Sendable (_ photos: [MeasuredPhoto], _ done: @escaping @Sendable (Int) -> Void,
                                   _ isCancelled: @escaping @Sendable () -> Bool) -> Measurement

    /// Runs auto or match_look, or returns nil when `tool` is neither. Measuring happens off the
    /// main thread; the change itself goes through `write` like every other edit.
    func callMeasuring(_ tool: String, _ arguments: [String: JSONValue], client: AgentClient,
                       profile: AgentProfile) async -> MCPToolResult? {
        guard AtelierAgentTools.measuringTools.contains(where: { $0.name == tool }) else { return nil }
        guard profile >= .edit else {
            return .error("\(tool) needs the Edit profile. The person can change that in Atelier > Settings… > Agents.")
        }
        guard let model else { return .error("\(Self.appName) is closing.") }
        if let busy = model.agentProgress {
            return .error("Atelier is already measuring photos for an agent (\(busy.phase)). Try again when it ends.")
        }
        do {
            switch tool {
            case AtelierAgentTools.auto.name:
                let parameters = try decode(AutoParameters.self, arguments)
                guard let title = parameters.title else {
                    throw ArgumentProblem("Turn on tone or white_balance: there is nothing to do.")
                }
                let photos = try measuredPhotos(parameters, model)
                return try await measureThenWrite(photos, targets: parameters, title: title, client, model,
                                                  measure: Self.autoMeasure(tone: parameters.tone ?? true,
                                                                            whiteBalance: parameters.whiteBalance ?? false))
            default:
                let parameters = try decode(MatchLookParameters.self, arguments)
                let (title, measure) = try matchLookMeasure(parameters, model)
                let photos = try measuredPhotos(parameters, model)
                return try await measureThenWrite(photos, targets: parameters, title: title, client, model, measure: measure)
            }
        } catch let problem as ArgumentProblem {
            return .error(problem.message)
        } catch {
            return .error("Atelier couldn't make the change: \(error.localizedDescription)")
        }
    }

    /// The photos a call names, with their files and settings now.
    private func measuredPhotos(_ targets: PhotoTargeting, _ model: LibraryModel) throws -> [MeasuredPhoto] {
        let ids = try resolve(targets, model)
        let settings = try model.develop.currentSettings(for: ids)
        var offline: [Int64] = []
        let photos = ids.compactMap { id -> MeasuredPhoto? in
            guard let url = try? model.catalog.fileURL(for: id), let current = settings[id] else {
                offline.append(id)
                return nil
            }
            return MeasuredPhoto(id: id, url: url, settings: current)
        }
        if !offline.isEmpty {
            throw ArgumentProblem("The originals of \(Self.count(offline.count)) are offline (ids "
                                  + "\(offline.prefix(20).map(String.init).joined(separator: ", "))): Atelier needs their "
                                  + "pixels. Nothing was changed; connect the drive or leave them out.")
        }
        return photos
    }

    private func measureThenWrite(_ photos: [MeasuredPhoto], targets: PhotoTargeting, title: String, _ client: AgentClient,
                                  _ model: LibraryModel, measure: @escaping Measure) async throws -> MCPToolResult {
        let total = photos.count
        let name = client.name
        let phase: @Sendable (Int) -> String = { done in "\(name): \(title), \(min(done + 1, total)) of \(total)" }
        let jobID = UUID()
        let work = Task.detached(priority: .userInitiated) { () -> Measurement in
            measure(photos, { done in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Not once the job has ended (a late update must not bring the bar back).
                        guard model.agentJob?.id == jobID, model.agentProgress?.phase != Self.cancelling else { return }
                        model.agentProgress = ImportStatus(phase: phase(done), fraction: Double(done) / Double(max(1, total)))
                    }
                }
            }, { Task.isCancelled })
        }
        let job = AgentJob(id: jobID) { [weak model] in
            work.cancel()
            model?.agentProgress = ImportStatus(phase: Self.cancelling, fraction: nil)
        }
        model.agentJob = job
        model.agentProgress = ImportStatus(phase: phase(0), fraction: 0)
        log(client.name, .call, "\(title): measuring \(Self.count(total))")
        let found = await work.value
        if model.agentJob?.id == job.id {
            model.agentJob = nil
            model.agentProgress = nil
        }
        if work.isCancelled {
            return .error("The person cancelled \(title) in Atelier. Nothing was changed.")
        }
        // The change itself waits for a drag in progress, like every Develop edit.
        guard await waitForDevelopIdle() else {
            return .error("The person is still dragging in Develop. Nothing was changed; try again in a moment.")
        }
        // Only photos still as they were measured get the change: one edited by hand or removed
        // meanwhile is left alone and named.
        let ids = photos.map(\.id).filter { found.settings[$0] != nil }
        let now = try model.develop.currentSettings(for: ids)
        let measuredFrom = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.settings) })
        let changed = ids.filter { now[$0] != measuredFrom[$0] }
        let ready = ids.filter { !changed.contains($0) }
        guard !ready.isEmpty else {
            if !changed.isEmpty {
                return .error("Target changed: these photos were edited or removed while Atelier measured them. Nothing "
                              + "was changed; try again.")
            }
            return .error("Atelier couldn't measure \(photos.count == 1 ? "this photo" : "these photos")"
                          + (found.notes.isEmpty ? "." : ": " + found.notes.joined(separator: " ")) + " Nothing was changed.")
        }
        let step = "\(title) (\(client.name))"
        let result = try write(MeasuredTargets(ids: ready, catalog: catalogName), title: title, client, model,
                               kind: .develop) { named, _ in
            try model.develop.apply(each: found.settings.filter { named.contains($0.key) }, step: step)
        }
        var notes = found.notes
        if !changed.isEmpty {
            notes.append("Left alone because they changed while Atelier measured: ids "
                         + changed.prefix(20).map(String.init).joined(separator: ", ") + ".")
        }
        if !found.failed.isEmpty {
            notes.append("Couldn't be measured (unreadable files): ids "
                         + found.failed.prefix(20).map(String.init).joined(separator: ", ") + ".")
        }
        var members: [String: JSONValue] = [:]
        if !notes.isEmpty { members["note"] = .string(notes.joined(separator: " ")) }
        if !changed.isEmpty { members["skipped_ids"] = .array(changed.prefix(200).map { .int(Int($0)) }) }
        return adding(members, to: result)
    }

    nonisolated static let cancelling = "Cancelling…"

    private struct MeasuredTargets: PhotoTargeting {
        var ids: [Int64]?
        var selection: Bool? { nil }
        var current: Bool? { nil }
        var catalog: String?
    }

    /// Basic > Auto and Auto White Balance, as the buttons do them, on each photo's own pixels
    /// (the same proxy size Develop measures the open photo at).
    nonisolated static func autoMeasure(tone: Bool, whiteBalance: Bool) -> Measure {
        { photos, done, isCancelled in
            var result = Measurement()
            for (index, photo) in photos.enumerated() {
                if isCancelled() { break }
                done(index)
                guard let session = DevelopRenderer.shared.session(for: photo.url, maxPixelSize: DevelopController.proxySize)
                else {
                    result.failed.append(photo.id)
                    continue
                }
                var settings = photo.settings
                if whiteBalance {
                    guard let found = WhiteBalance.neutral(session: session, settings: settings,
                                                           asShotTint: session.asShotTint) else {
                        result.failed.append(photo.id)
                        continue
                    }
                    settings.temperature = found.temperature
                    settings.tint = found.tint
                }
                if tone {
                    guard let found = AutoTone.apply(session: session, settings: settings) else {
                        result.failed.append(photo.id)
                        continue
                    }
                    for parameter in AutoTone.parameters { settings[parameter] = found[parameter] }
                }
                result.settings[photo.id] = settings
            }
            return result
        }
    }

    /// match_look's reference, checked on the main thread, and the fit to run in the background,
    /// as the Match Look dialog fits (Same settings or Match each photo).
    private func matchLookMeasure(_ p: MatchLookParameters, _ model: LibraryModel) throws -> (String, Measure) {
        let problems = MatchLookRules.check(p)
        guard problems.isEmpty else { throw ArgumentProblem(problems.joined(separator: " ")) }
        let study: BuiltInLookReference?
        let referenceName: String
        let loadReference: @Sendable () -> CGImage?
        if let name = p.study {
            switch MatchLookRules.study(named: name) {
            case .failure(let problems): throw ArgumentProblem(problems.text)
            case .success(let index):
                let found = BuiltInLookReference.allCases[index]
                study = found
                referenceName = found.name
                loadReference = { found.image() }
            }
        } else {
            let id = try resolve(MeasuredTargets(ids: [p.reference ?? 0], catalog: p.catalog), model)[0]
            guard let url = try model.catalog.fileURL(for: id) else {
                throw ArgumentProblem("The reference photo \(id)'s original is offline. Nothing was changed.")
            }
            let settings = try model.develop.currentSettings(for: [id])[id] ?? .neutral
            study = nil
            referenceName = url.lastPathComponent
            // As the dialog's "a catalog photo with its current edits".
            loadReference = { DevelopRenderer.shared.session(for: url, maxPixelSize: 1024)?.renderSRGB(settings) }
        }
        let areas: LookAreas
        switch p.areas {
        case .subject?:
            if let study, !study.isPortrait {
                throw ArgumentProblem("“\(study.name)” is a wide study: it only takes areas whole_photo.")
            }
            areas = .subject
        case .wholePhoto?: areas = .wholePhoto
        case nil: areas = study?.isPortrait == true ? .subject : .wholePhoto
        }
        let skinGiven = p.skin != nil
        let skin: LookSkinMode
        switch p.skin ?? .protect {
        case .off: skin = .off
        case .protect: skin = .protect
        case .match: skin = .match
        }
        let options = LookMatchOptions(whiteBalance: p.whiteBalance ?? true, tone: p.tone ?? true, color: p.color ?? true,
                                       skinMode: skin)
        let strength = (p.strength ?? 100) / 100
        let each = p.fit == .each || skin == .match
        let measure: Measure = { photos, done, isCancelled in
            var result = Measurement()
            guard let image = loadReference(),
                  let target = MatchLookModel.lookTarget(reference: image, study: study, areas: areas, options: options,
                                                         features: FeatureCache()) else {
                result.failed = photos.map(\.id)
                result.notes.append("Atelier can't read “\(referenceName)” as a reference.")
                return result
            }
            var notices: Set<LookMatchNotice> = []
            var shared: LookMatch?
            for (index, photo) in photos.enumerated() {
                if isCancelled() { break }
                done(index)
                if let shared {
                    result.settings[photo.id] = shared.applied(to: photo.settings, strength: strength)
                    continue
                }
                guard let match = LibraryModel.fitLook(url: photo.url, settings: photo.settings, target: target,
                                                       options: options, isCancelled: isCancelled) else {
                    if isCancelled() { break }
                    result.failed.append(photo.id)
                    continue
                }
                notices.formUnion(match.notices)
                result.settings[photo.id] = match.settings(strength: strength)
                // Same settings, unless the match adds skin masks, which belong to each photo's faces.
                if !each, match.skinMasks.isEmpty { shared = match }
            }
            // Protect is the default; a photo without faces simply has none to protect.
            if !skinGiven { notices.remove(.noFaces) }
            if let message = MatchLookModel.message(for: notices) { result.notes.append(message) }
            return result
        }
        return ("Match Look: \(referenceName)", measure)
    }
}

extension AgentPeoplePart {
    var part: DevelopSettings.PeopleSelection.Part? {
        switch self {
        case .faceSkin: return .faceSkin
        case .bodySkin: return .bodySkin
        case .eyebrows: return .eyebrows
        case .eyeSclera: return .eyeSclera
        case .iris: return .iris
        case .lips: return .lips
        case .teeth: return .teeth
        case .hair: return .hair
        case .clothes: return .clothes
        case .entirePerson: return .entirePerson
        case .entireFace: return .entireFace
        }
    }
}
