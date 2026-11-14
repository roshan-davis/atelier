import CoreGraphics
import Foundation
import os
import Vision

// Match Look Phase 3: Protect Skin Tones and Subject & Background. See the PRD's "Match Look to a
// Reference".

/// Which parts of the two images should match.
public enum LookAreas: Sendable, Equatable {
    /// The whole reference to the whole photo.
    case wholePhoto
    /// Match Areas' boxes, 0 to 1 from the top left of each image.
    case boxes(reference: CGRect, photo: CGRect)
    /// Subject & Background: Vision finds the subject in both images. The global sliders are
    /// fitted background to background and a "Match Look: Subject" mask subject to subject.
    case subject
}

/// Something the dialog should tell the user about a match.
public enum LookMatchNotice: Sendable, Hashable {
    /// Protect Skin Tones found no face in the photo, so it had nothing to protect.
    case noFaces
    case noSkinInPhoto
    case noSkinInReference
    case skinMatchLimited
    /// Subject & Background found no subject in the photo; the whole photo was matched.
    case noSubjectInPhoto
    /// Subject & Background found no subject in the reference; the whole photo was matched.
    case noSubjectInReference
}

/// The skin on a photo's faces, measured once on the photo before the match.
public struct LookSkin: Sendable {
    /// Protect Skin Tones' limits: skin's Oklab hue moves at most this many degrees…
    public static let maxHueShift = 5.0
    /// …and its chroma (saturation) by at most this fraction.
    public static let maxChromaChange = 0.15

    /// The sample's pixels that are skin.
    let pixels: [Int]
    let faces: [CGRect]
    /// Whether the skin came from Select People (face and body skin), so the skin mask the match
    /// adds is a Select People part; otherwise it's ellipses on the face boxes.
    let usesPeople: Bool
    /// Skin's Oklab hue (degrees) and mean chroma before the match.
    let hue: Double
    let chroma: Double
    /// The mean Oklab a/b of the skin's shadows, midtones and highlights: drawn regions for a
    /// built-in study, otherwise the darkest, middle and brightest thirds of its pixels.
    let toneColors: [SIMD2<Double>]
    /// The mean Oklab lightness of the same three tones, which Protect Skin Tones also holds.
    let toneLightness: [Double]

    /// Faces Vision finds, 0 to 1 from the top left.
    public static func faces(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).map { face in
            let box = face.boundingBox
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }

    /// Skin-colored pixels inside the middle of each face (leaving out hair, eyes' surroundings
    /// and background at the box edges). Nil when there are too few to measure.
    init?(sample: LookSample, faces: [CGRect], authored: Bool = false) {
        guard !faces.isEmpty, sample.width > 0, sample.height > 0 else { return nil }
        var picked: [Int] = []
        var usableFaces: [CGRect] = []
        for face in faces {
            let region = authored ? face : CGRect(x: face.minX + face.width * 0.18,
                                                  y: face.minY + face.height * 0.2,
                                                  width: face.width * 0.64, height: face.height * 0.72)
            let x0 = max(0, Int((region.minX * CGFloat(sample.width)).rounded()))
            let x1 = min(sample.width, Int((region.maxX * CGFloat(sample.width)).rounded()))
            let y0 = max(0, Int((region.minY * CGFloat(sample.height)).rounded()))
            let y1 = min(sample.height, Int((region.maxY * CGFloat(sample.height)).rounded()))
            guard x1 > x0, y1 > y0 else { continue }
            var facePixels: [Int] = []
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * sample.width + x
                    if authored || Self.looksLikeSkin(sample, i) { facePixels.append(i) }
                }
            }
            guard facePixels.count >= 12 else { continue }
            usableFaces.append(face)
            picked += facePixels
        }
        guard let first = Self.hueAndChroma(sample, picked) else { return nil }
        // Leave out the odd pixel far from the face's own skin color (lips, shadows, glasses).
        let kept = picked.filter { i in
            let h = atan2(Double(sample.b[i]), Double(sample.a[i])) * 180 / .pi
            return abs(Self.hueDifference(h, first.hue)) < 25
        }
        let used = kept.count >= 12 ? kept : picked
        guard let measured = Self.hueAndChroma(sample, used) else { return nil }
        let skin = Array(Set(used)).sorted()
        pixels = skin
        self.faces = usableFaces
        usesPeople = false
        hue = measured.hue
        chroma = measured.chroma
        let groups = Self.toneSplit(sample, skin).groups
        toneColors = groups.compactMap { Self.meanAB(sample, $0) }
        toneLightness = groups.compactMap { Self.meanLightness(sample, $0) }
    }

    /// A built-in study's skin, drawn in flat tones: one region per tone (shadows, midtones,
    /// highlights, 0 to 1 from the top left), every pixel in each taken as skin. The overall hue
    /// and chroma are the midtone's. Nil unless all three regions hold pixels.
    init?(sample: LookSample, toneRegions: [CGRect]) {
        guard toneRegions.count == 3, sample.width > 0, sample.height > 0 else { return nil }
        let groups = toneRegions.map { Self.pixels(in: $0, of: sample) }
        guard groups.allSatisfy({ $0.count >= 4 }), let mid = Self.hueAndChroma(sample, groups[1]) else { return nil }
        pixels = Array(Set(groups.joined())).sorted()
        faces = toneRegions
        usesPeople = false
        hue = mid.hue
        chroma = mid.chroma
        toneColors = groups.compactMap { Self.meanAB(sample, $0) }
        toneLightness = groups.compactMap { Self.meanLightness(sample, $0) }
    }

    static func pixels(in region: CGRect, of sample: LookSample) -> [Int] {
        let x0 = max(0, Int((region.minX * CGFloat(sample.width)).rounded()))
        let x1 = min(sample.width, Int((region.maxX * CGFloat(sample.width)).rounded()))
        let y0 = max(0, Int((region.minY * CGFloat(sample.height)).rounded()))
        let y1 = min(sample.height, Int((region.maxY * CGFloat(sample.height)).rounded()))
        guard x1 > x0, y1 > y0 else { return [] }
        return (y0..<y1).flatMap { y in (x0..<x1).map { y * sample.width + $0 } }
    }

    /// The pixels split into their darkest, middle and brightest thirds by brightness, with the
    /// two brightness levels between them (0 to 1). Brightness is measured as a mask's Luminance
    /// Range reads it (`rangeLuma`), so the skin tone masks' ranges cut where the thirds do.
    static func toneSplit(_ sample: LookSample, _ pixels: [Int]) -> (groups: [[Int]], cuts: (Double, Double)) {
        let valid = pixels.filter { $0 < sample.count }
        let brightness = Dictionary(uniqueKeysWithValues: Set(valid).map { ($0, rangeLuma(sample, $0)) })
        let sorted = valid.sorted { brightness[$0, default: 0] < brightness[$1, default: 0] }
        guard sorted.count >= 3 else { return ([], (1.0 / 3, 2.0 / 3)) }
        let first = sorted.count / 3, second = sorted.count * 2 / 3
        let groups = [Array(sorted[..<first]), Array(sorted[first..<second]), Array(sorted[second...])]
        return (groups, (brightness[sorted[first], default: 0], brightness[sorted[second], default: 0]))
    }

    /// A pixel's brightness as a mask's Luminance Range reads it: the linear luminance, sRGB
    /// encoded (`MaskRenderer.luminanceMask`). The sample's own `luma` is luma of the encoded
    /// values, a few percent off on skin, so the ranges sat off the thirds they were fitted for.
    static func rangeLuma(_ sample: LookSample, _ i: Int) -> Double {
        let rgb = Oklab.toLinear(SIMD3(Double(sample.lightness[i]), Double(sample.a[i]), Double(sample.b[i])))
        let luminance = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        return Oklab.encoded(min(1, max(0, luminance)))
    }

    /// Mean Oklab lightness of the pixels.
    static func meanLightness(_ sample: LookSample, _ pixels: [Int]) -> Double? {
        var sum = 0.0, n = 0.0
        for i in pixels where i < sample.count {
            sum += Double(sample.lightness[i])
            n += 1
        }
        return n > 0 ? sum / n : nil
    }

    /// The pixels' color relative to their brightness: mean Oklab a/b over mean Oklab lightness.
    /// How saturated skin looks goes with chroma over lightness, so this is what Match Skin Tone
    /// matches: the same a/b on a brighter face looks paler, on a darker one deeper. Matching
    /// the reference's absolute a/b while the face kept its own brightness overshot a dark
    /// photo's shadows by 44% against Fury Road and left Thrones' pale skin 32% too saturated
    /// (Rosh, Nov 14, 2026). Nil when the pixels are nearly black.
    static func relativeAB(_ sample: LookSample, _ pixels: [Int]) -> SIMD2<Double>? {
        guard let ab = meanAB(sample, pixels), let lightness = meanLightness(sample, pixels), lightness > 0.05 else {
            return nil
        }
        return ab / lightness
    }

    /// The skin's shadows, midtones and highlights as `relativeAB` measures them; empty unless
    /// both the colors and the lightness of all three tones are known.
    var relativeToneColors: [SIMD2<Double>] {
        guard toneColors.count == 3, toneLightness.count == 3, toneLightness.allSatisfy({ $0 > 0.05 }) else { return [] }
        return zip(toneColors, toneLightness).map { $0 / $1 }
    }

    /// Mean Oklab a/b of the pixels.
    static func meanAB(_ sample: LookSample, _ pixels: [Int]) -> SIMD2<Double>? {
        var sum = SIMD2<Double>(0, 0), n = 0.0
        for i in pixels where i < sample.count {
            sum += SIMD2(Double(sample.a[i]), Double(sample.b[i]))
            n += 1
        }
        return n > 0 ? sum / n : nil
    }

    /// The skin Select People finds (face and body skin, 1 is skin) at the sample's size. Nil
    /// when there's too little to measure.
    init?(sample: LookSample, skin values: [Double], faces: [CGRect]) {
        guard values.count == sample.count else { return nil }
        let picked = values.indices.filter { values[$0] >= 0.5 }
        guard picked.count >= 12, let measured = Self.hueAndChroma(sample, picked) else { return nil }
        pixels = picked
        self.faces = faces
        usesPeople = true
        hue = measured.hue
        chroma = measured.chroma
        let groups = Self.toneSplit(sample, picked).groups
        toneColors = groups.compactMap { Self.meanAB(sample, $0) }
        toneLightness = groups.compactMap { Self.meanLightness(sample, $0) }
    }

    /// What the skin treatments measure and Match Skin Tone adjusts: everyone's Face Skin. Body
    /// Skin is found by color alone, so warm clothes touching skin can join it; it stays a choice
    /// in Masking.
    public static let matchSelection = DevelopSettings.PeopleSelection(parts: [.faceSkin], feather: 0)

    /// What the skin masks cover: the Entire Face in one piece, softly edged. Built from Face
    /// Skin and the feature parts, the masks took some shaded teeth and brow edges and left
    /// other pockets out, so the face showed disjointed colors (Rosh, Nov 11, 2026). Now one base
    /// color covers the whole face and the shadow and highlight masks blend in on top of it.
    /// With `bodySkin` (the built-in parts model is loaded, so Body Skin is the model's, not a
    /// color guess that leaks into warm clothes) the neck, arms and hands take the same change:
    /// a face matched alone left a line at the collar (Rosh, Nov 14, 2026). Skin is still
    /// measured on Face Skin, so the face decides the change and the neck follows it.
    static func maskSelection(bodySkin: Bool) -> DevelopSettings.PeopleSelection {
        DevelopSettings.PeopleSelection(parts: bodySkin ? [.entireFace, .bodySkin] : [.entireFace], feather: 20)
    }

    /// Taken back out of Match Skin Tone's masks: the eyes' whites and irises. Entire Face
    /// includes them so the skin has no holes, but a skin color move would tint the whites.
    /// Protect Skin Tones keeps them in, since it holds the face as it was.
    static let eyesSelection = DevelopSettings.PeopleSelection(parts: [.eyeSclera, .iris], feather: 5)

    /// Select People's face skin on an image, at `width` × `height`, with the faces it found; nil
    /// when it finds no one.
    static func people(in image: CGImage, width: Int, height: Int) -> (values: [Double], faces: [CGRect])? {
        guard let found = PeopleSkin.find(in: image),
              let mask = found.mask(matchSelection),
              let values = LookSample.focusValues(mask, width: width, height: height) else { return nil }
        return (values, found.people.map(\.face))
    }

    static func looksLikeSkin(_ sample: LookSample, _ i: Int) -> Bool {
        let l = Double(sample.lightness[i]), a = Double(sample.a[i]), b = Double(sample.b[i])
        let c = (a * a + b * b).squareRoot()
        guard l > 0.3, l < 0.93, c > 0.02, c < 0.2 else { return false }
        let h = atan2(b, a) * 180 / .pi
        return h > 15 && h < 110
    }

    /// Mean hue (from the mean a/b) and mean chroma of the pixels.
    static func hueAndChroma(_ sample: LookSample, _ pixels: [Int]) -> (hue: Double, chroma: Double)? {
        guard !pixels.isEmpty else { return nil }
        var a = 0.0, b = 0.0, c = 0.0
        for i in pixels where i < sample.count {
            let da = Double(sample.a[i]), db = Double(sample.b[i])
            a += da
            b += db
            c += (da * da + db * db).squareRoot()
        }
        let n = Double(pixels.count)
        return (atan2(b, a) * 180 / .pi, c / n)
    }

    static func hueDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    /// How far a render moved the skin: hue in degrees and the chroma ratio.
    func drift(_ sample: LookSample) -> (hue: Double, ratio: Double)? {
        guard let now = Self.hueAndChroma(sample, pixels), chroma > 1e-4 else { return nil }
        return (Self.hueDifference(now.hue, hue), now.chroma / chroma)
    }

    /// Whether a render left the skin where it was, closely: what Protect Skin Tones aims for
    /// before its looser limits (`isWithin`) are a fallback. Brightness counts too, since a look
    /// that lifts the face's tones makes the skin pale even when its hue and saturation hold.
    func holds(_ sample: LookSample) -> Bool {
        guard !toneLightness.isEmpty, let d = drift(sample), let now = Self.meanLightness(sample, pixels) else {
            return false
        }
        // The tones are equal thirds, so their mean is the skin's mean.
        let was = toneLightness.reduce(0, +) / Double(toneLightness.count)
        return abs(d.hue) <= 1.5 && abs(d.ratio - 1) <= 0.04 && abs(now - was) <= 0.015
    }

    func isWithin(_ sample: LookSample) -> Bool {
        guard let d = drift(sample) else { return false }
        return abs(d.hue) <= Self.maxHueShift && abs(d.ratio - 1) <= Self.maxChromaChange
    }

    /// Added to the refinement's score: nothing inside the limits, growing past them.
    func penalty(_ sample: LookSample) -> Double {
        guard let d = drift(sample) else { return 0 }
        return 0.002 * (max(0, abs(d.hue) - Self.maxHueShift) + 30 * max(0, abs(d.ratio - 1) - Self.maxChromaChange))
    }
}

/// What Vision finds in a reference, found once per reference and reused for every refit.
public struct LookReferenceFeatures: Sendable {
    /// Select Subject's mask at the sample's size, or nil when it finds none (or it covers almost
    /// nothing or almost everything).
    let subject: [Double]?
    let faces: [CGRect]
    /// Select People's face and body skin at the sample's size, or nil when it finds no one.
    let skin: [Double]?

    public init(image: CGImage) {
        let size = LookSample.sampleSize(of: image)
        let mask: CGImage? = (try? AIImaging.subjectMask(for: image)) ?? nil
        subject = mask
            .flatMap { LookSample.focusValues($0, width: size.width, height: size.height) }
            .flatMap { LookMatcher.isUsableSubject($0) ? $0 : nil }
        let people = LookSkin.people(in: image, width: size.width, height: size.height)
        skin = people?.values
        faces = people?.faces ?? LookSkin.faces(in: image)
    }

    /// Features that are known rather than found, as for a built-in study: its drawn person as
    /// the subject mask (white is the subject) and its face boxes (0 to 1 from the top left).
    public init(image: CGImage, subjectMask: CGImage, faces: [CGRect]) {
        let size = LookSample.sampleSize(of: image)
        subject = LookSample.focusValues(subjectMask, width: size.width, height: size.height)
            .flatMap { LookMatcher.isUsableSubject($0) ? $0 : nil }
        self.faces = faces
        // A study's skin is drawn (`authoredSkinTones`), not found.
        skin = nil
    }

    public var hasSubject: Bool { subject != nil }
    public var hasFaces: Bool { !faces.isEmpty }
}

/// The reference, measured for a match with these areas and options.
public struct LookTarget: Sendable {
    public let areas: LookAreas
    /// The whole reference, or weighted to Match Areas' box.
    let whole: LookSample
    /// Subject & Background: the reference weighted to its background, and its subject alone.
    let background: LookSample?
    let subject: LookSample?
    let notices: Set<LookMatchNotice>
    let skin: LookSkin?

    /// `authoredSkinTones` are a built-in study's drawn skin samples (shadows, midtones,
    /// highlights); `authoredSkinRegions` drawn samples of a single tone. `colorStudy` marks a
    /// built-in study, which gives color only (see `LookSample.isColorStudy`).
    public init?(image: CGImage, features: LookReferenceFeatures? = nil, areas: LookAreas,
                 skinMode: LookSkinMode = .off, authoredSkinRegions: [CGRect]? = nil,
                 authoredSkinTones: [CGRect]? = nil, colorStudy: Bool = false) {
        guard var plain = LookSample(image: image) else { return nil }
        plain.isColorStudy = colorStudy
        self.areas = areas
        var notices: Set<LookMatchNotice> = []
        let features = features ?? (areas == .subject ? LookReferenceFeatures(image: image) : nil)
        if skinMode == .off {
            skin = nil
        } else if let authoredSkinTones {
            skin = LookSkin(sample: plain, toneRegions: authoredSkinTones)
        } else if let authoredSkinRegions {
            skin = LookSkin(sample: plain, faces: authoredSkinRegions, authored: true)
        } else if let found = Self.peopleSkin(plain, image: image, features: features) {
            // Select People's face and body skin; face boxes when it finds no one.
            skin = found
        } else {
            skin = LookSkin(sample: plain, faces: features?.faces ?? LookSkin.faces(in: image))
        }
        // Protect leaves face skin out of the global fit. Match uses the ordinary area fit
        // first, then corrects faces locally against the reference measurement.
        let excluded = skinMode == .protect ? skin?.pixels ?? [] : []
        if skinMode == .match, skin == nil { notices.insert(.noSkinInReference) }
        var background: LookSample?, subject: LookSample?
        switch areas {
        case .wholePhoto:
            break
        case .boxes(let reference, _):
            plain = LookSample(image: image, area: reference) ?? plain
            plain.isColorStudy = colorStudy
        case .subject:
            if let mask = features?.subject, mask.count == plain.count {
                var back = plain, front = plain
                back.focusWeights(mask.map { 1 - $0 }, share: LookSample.areaShare)
                front.focusWeights(mask, share: 1)
                background = back.excluding(excluded)
                subject = front.excluding(excluded)
            } else {
                notices.insert(.noSubjectInReference)
            }
        }
        whole = plain.excluding(excluded)
        self.background = background
        self.subject = subject
        self.notices = notices
    }
}

extension LookTarget {
    /// The reference's face and body skin from Select People, from `features` when they were
    /// found already.
    static func peopleSkin(_ sample: LookSample, image: CGImage, features: LookReferenceFeatures?) -> LookSkin? {
        if let features {
            guard let values = features.skin else { return nil }
            return LookSkin(sample: sample, skin: values, faces: features.faces)
        }
        guard let people = LookSkin.people(in: image, width: sample.width, height: sample.height) else { return nil }
        return LookSkin(sample: sample, skin: people.values, faces: people.faces)
    }
}

extension LookMatcher {
    /// Feather of the Select Subject part Subject & Background adds, as the Masks panel's default.
    public static let subjectFeather = 20.0

    /// Whether a subject mask is worth matching by: at least 3% of the image, at most 95%.
    static func isUsableSubject(_ values: [Double]) -> Bool {
        guard !values.isEmpty else { return false }
        let share = values.reduce(0, +) / Double(values.count)
        return share > 0.03 && share < 0.95
    }

    /// Fits `settings` on `session`'s photo to `target`, with Match Areas, Subject & Background
    /// and Protect Skin Tones. `photoFaces` (0 to 1 from the top left) are the photo's faces when
    /// already found (the dialog finds them on its larger preview, so small faces aren't missed;
    /// tests pass their own); nil finds them on the fit render. Returns nil when the photo can't be
    /// rendered.
    public static func match(session: DevelopSession, settings base: DevelopSettings, target: LookTarget,
                             options: LookMatchOptions = LookMatchOptions(), photoFaces: [CGRect]? = nil,
                             isCancelled: () -> Bool = { false }) -> LookMatch? {
        // A built-in study gives color only: its brightness is the drawing's layout, and
        // matching it darkened photos and their faces.
        var options = options
        if target.whole.isColorStudy { options.tone = false }
        // Every step renders the photo at the fit size; the count and time are logged so slow
        // matches can be measured (Console, subsystem Atelier, category Match Look).
        let started = Date()
        var renders = 0
        func render(_ settings: DevelopSettings) -> CGImage? {
            renders += 1
            return session.renderSRGB(settings)
        }
        guard let baseImage = render(base), let plain = LookSample(image: baseImage) else { return nil }
        var notices = target.notices
        let asShot = session.asShotTemperature
        var skin: LookSkin?
        if options.skinMode != .off {
            // Select People's face skin, the same skin the "Match Look: Skin" mask adjusts; face
            // boxes when it finds no one.
            if let mask = session.peopleMask(base, selection: LookSkin.matchSelection),
               let values = LookSample.focusValues(mask, width: plain.width, height: plain.height) {
                skin = LookSkin(sample: plain, skin: values, faces: photoFaces ?? [])
            }
            skin = skin ?? LookSkin(sample: plain, faces: photoFaces ?? LookSkin.faces(in: baseImage))
            if skin == nil { notices.insert(options.skinMode == .protect ? .noFaces : .noSkinInPhoto) }
        }
        let skinPixels = options.skinMode == .protect ? skin?.pixels ?? [] : []

        // Where the photo is measured.
        var reference = target.whole
        var photoBox: CGRect?
        var subjectFocus: [Double]?
        switch target.areas {
        case .wholePhoto:
            break
        case .boxes(_, let photo):
            photoBox = photo
        case .subject:
            if let background = target.background, target.subject != nil {
                if let mask = session.subjectMask(base),
                   let values = LookSample.focusValues(mask, width: plain.width, height: plain.height),
                   isUsableSubject(values) {
                    subjectFocus = values
                    reference = background
                } else {
                    notices.insert(.noSubjectInPhoto)
                }
            }
        }

        // The fast stand-in (see LookEmulator): once White Balance and Exposure are fitted with
        // real renders, the photo is rendered once more with the later steps neutral, and the
        // other tries are worked out from that render. Tries it can't follow are rendered.
        var emulator: LookEmulator?
        var usesEmulator = true
        var plainWeighed: (settings: DevelopSettings, luma: [Float])?
        func photo(_ settings: DevelopSettings, area: CGRect? = nil) -> LookSample? {
            if usesEmulator, let emulator, emulator.follows(settings) { return emulator.sample(settings, area: area) }
            return render(settings).flatMap { LookSample(image: $0, area: area) }
        }
        /// Linear luma per sample pixel of a real render.
        func luma(_ settings: DevelopSettings) -> [Float]? {
            guard let image = render(settings), let data = LookSample.pixels(of: image) else { return nil }
            let linear = LookSample.linearTable
            let pixels = data.pixels
            var out = [Float](repeating: 0, count: data.width * data.height)
            for i in out.indices {
                let r: Double = linear[Int(pixels[i * 4])]
                let g: Double = linear[Int(pixels[i * 4 + 1])]
                let b: Double = linear[Int(pixels[i * 4 + 2])]
                out[i] = Float(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
            return out
        }
        /// A mask's weight per pixel: the photo rendered with only that mask, at Exposure -4,
        /// against the photo without it. Inside the mask the light drops to 1/16.
        func weigh(_ settings: DevelopSettings, _ mask: DevelopSettings.Mask) -> [Float]? {
            var plain = settings
            plain.masks.removeAll(where: LookEmulator.isEmulated)
            plain.grain = 0
            var dimmed = mask
            dimmed.resetAdjustments()
            dimmed.isHidden = false
            dimmed[.exposure] = -4
            var probe = plain
            probe.masks.append(dimmed)
            let before: [Float]
            if let known = plainWeighed, known.settings == plain {
                before = known.luma
            } else {
                guard let measured = luma(plain) else { return nil }
                plainWeighed = (plain, measured)
                before = measured
            }
            guard let after = luma(probe), after.count == before.count else { return nil }
            let drop = Float(1 - 1.0 / 16)
            var weights = [Float](repeating: 0, count: before.count)
            for i in weights.indices where before[i] >= 0.002 {
                let ratio: Float = after[i] / before[i]
                weights[i] = min(1, max(0, (1 - ratio) / drop))
            }
            return weights
        }

        func sample(_ settings: DevelopSettings) -> LookSample? {
            if let photoBox { return photo(settings, area: photoBox)?.excluding(skinPixels) }
            guard var measured = photo(settings) else { return nil }
            if let subjectFocus {
                measured.focusWeights(subjectFocus.map { 1 - $0 }, share: LookSample.areaShare)
            }
            return measured.excluding(skinPixels)
        }

        func whole(_ settings: DevelopSettings) -> LookSample? { photo(settings) }

        var current = base
        var penalty: ((LookSample) -> Double)?
        if options.skinMode == .protect, let skin { penalty = { measured in skin.penalty(measured) } }
        fitGlobal(&current, asShot: asShot, options: options, reference: reference, measure: sample,
                  penalty: penalty, afterDecode: { settings in
                      guard LookEmulator.supports(settings) else { return false }
                      let stage = LookEmulator.neutralStage(settings)
                      guard let image = render(stage) else { return false }
                      emulator = LookEmulator(stage: image, stageSettings: stage, weigh: weigh)
                      return emulator != nil
                  }, isCancelled: isCancelled)

        if let subjectFocus, let subjectReference = target.subject, !isCancelled() {
            func subjectSample(_ settings: DevelopSettings) -> LookSample? {
                guard var measured = photo(settings) else { return nil }
                measured.focusWeights(subjectFocus, share: 1)
                return measured.excluding(skinPixels)
            }
            fitSubject(&current, options: options, reference: subjectReference, measure: subjectSample)
        }

        if let skin, !isCancelled() {
            let size = CGSize(width: baseImage.width, height: baseImage.height)
            let space = MaskSpace(sourceSize: session.sourceSize, crop: base.crop ?? .init(),
                                  rect: CGRect(origin: .zero, size: size), outputSize: size)
            // Body Skin only from the built-in parts model: found by color alone it can take a
            // warm scarf or coat touching the neck.
            let bodySkin = skin.usesPeople && PeopleParts.isAvailable
            if options.skinMode == .protect {
                // Hold the skin at its own colors, tone by tone, with the skin masks, so the rest
                // of the photo keeps the full look. Only if that can't bring it back inside the
                // limits are the sliders pulled back (which weakens the whole match).
                // The masks hold the skin's brightness too and act on any visible drift, not only
                // past the limits: a face 4% less saturated and a little lighter read as pale.
                if let now = whole(current), !skin.holds(now) {
                    // The masks may move as far as needed: they undo the look on the face,
                    // rather than paint the face like Match Skin Tone does.
                    _ = fitSkin(skin, to: skin, in: &current, space: space, measure: whole,
                                limit: protectSkinShift, holdsLightness: true, bodySkin: bodySkin,
                                isCancelled: isCancelled)
                }
                if !isCancelled(), let now = whole(current), !skin.isWithin(now) {
                    protect(skin, in: &current, from: base, asShot: asShot, options: options, measure: whole)
                }
            } else if let referenceSkin = target.skin {
                let fit = fitSkin(skin, to: referenceSkin, in: &current, space: space,
                                  measure: whole, bodySkin: bodySkin, isCancelled: isCancelled)
                if fit.outcome == .unchanged { notices.insert(.skinMatchLimited) }
            }
        }
        // The stand-in is close but not exact: check with a real render, and settle Exposure
        // (the step most of the others lean on) on it.
        var offBy = 0.0
        if let emulator, !isCancelled() {
            let guess = emulator.follows(current) ? emulator.sample(current) : nil
            usesEmulator = false
            if let guess, let real = whole(current) { offBy = guess.distance(to: real) }
            if options.tone { fitExposure(&current, reference: reference, measure: sample) }
            if options.skinMode == .protect, let skin, let now = whole(current), !skin.isWithin(now) {
                protect(skin, in: &current, from: base, asShot: asShot, options: options, measure: whole)
            }
        }
        guard !isCancelled() else { return nil }
        lastMatchRenders = renders
        let seconds = Date().timeIntervalSince(started)
        Logger(subsystem: "Atelier", category: "Match Look").info(
            "Match: \(renders) renders, \(emulator?.tries ?? 0) stand-in tries in \(seconds, format: .fixed(precision: 2)) s at \(plain.width)×\(plain.height); stand-in off by \(offBy, format: .fixed(precision: 4))")
        var match = LookMatch(base: base, matched: current, asShotTemperature: asShot, notices: notices)
        match.subjectFitParameters = options.subjectFitParameters
        return match
    }

    /// Real renders the last match made, for tests.
    nonisolated(unsafe) static var lastMatchRenders = 0

    // MARK: Subject & Background

    static let maxSubjectTemp = 60.0
    static let maxSubjectTint = 60.0
    static let maxSubjectExposure = 1.5
    static let maxSubjectSaturation = 60.0

    /// Adds a "Match Look: Subject" mask (Select Subject) and fits its Temp, Tint, Exposure and
    /// Saturation so the photo's subject matches the reference's, once the background matches.
    /// The slopes are measured by rendering a nudge of each slider, as the global fit does.
    static func fitSubject(_ settings: inout DevelopSettings, options: LookMatchOptions, reference: LookSample,
                           measure: (DevelopSettings) -> LookSample?) {
        let earlier = settings.masks.firstIndex { $0.name == LookMatch.subjectMaskName }
        let index = earlier ?? settings.masks.count
        if earlier == nil {
            let part = DevelopSettings.MaskComponent(.subject(DevelopSettings.Selection(feather: subjectFeather)))
            settings.masks.append(DevelopSettings.Mask(name: LookMatch.subjectMaskName, components: [part]))
        }
        for parameter in options.subjectFitParameters { settings.masks[index][parameter] = 0 }
        func with(_ changes: [(DevelopSettings.LocalParameter, Double)]) -> DevelopSettings {
            var out = settings
            for (parameter, value) in changes { out.masks[index][parameter] = value }
            return out
        }

        if options.whiteBalance {
            let target = reference.midtoneAB
            var temp = 0.0, tint = 0.0
            for _ in 0..<3 {
                guard let photo = measure(with([(.temperature, temp), (.tint, tint)])) else { break }
                let error = target - photo.midtoneAB
                if (error * error).sum() < 0.0015 * 0.0015 { break }
                guard let warmer = measure(with([(.temperature, temp + 15), (.tint, tint)])),
                      let greener = measure(with([(.temperature, temp), (.tint, tint + 15)])) else { break }
                let j1 = (warmer.midtoneAB - photo.midtoneAB) / 15, j2 = (greener.midtoneAB - photo.midtoneAB) / 15
                let det = j1.x * j2.y - j2.x * j1.y
                guard abs(det) > 1e-12 else { break }
                let dTemp = (error.x * j2.y - j2.x * error.y) / det
                let dTint = (j1.x * error.y - error.x * j1.y) / det
                temp = min(maxSubjectTemp, max(-maxSubjectTemp, temp + min(30, max(-30, dTemp))))
                tint = min(maxSubjectTint, max(-maxSubjectTint, tint + min(30, max(-30, dTint))))
            }
            settings.masks[index][.temperature] = temp.rounded()
            settings.masks[index][.tint] = tint.rounded()
        }

        if options.tone {
            let target = reference.medianLightness
            var exposure = 0.0
            for _ in 0..<2 {
                guard let photo = measure(with([(.exposure, exposure)])) else { break }
                let median = photo.medianLightness
                guard median > 0.02, target > 0.02 else { break }
                let stops = 3 * log2(target / median)
                if abs(stops) < 0.03 { break }
                exposure = min(maxSubjectExposure, max(-maxSubjectExposure, exposure + stops))
            }
            settings.masks[index][.exposure] = (exposure * 100).rounded() / 100
        }

        if options.color, reference.meanChroma > 0.005 {
            let target = reference.meanChroma
            var saturation = 0.0
            for _ in 0..<2 {
                guard let photo = measure(with([(.saturation, saturation)])), photo.meanChroma > 0.005,
                      let probed = measure(with([(.saturation, saturation + 20)])) else { break }
                let error = target - photo.meanChroma
                if abs(error) < 0.02 * target { break }
                let slope = (probed.meanChroma - photo.meanChroma) / 20
                guard slope > 1e-6 else { break }
                saturation = min(maxSubjectSaturation, max(-maxSubjectSaturation, saturation + error / slope))
            }
            settings.masks[index][.saturation] = saturation.rounded()
        }

        // A mask that moves nothing isn't worth adding.
        if earlier == nil, !settings.masks[index].hasAdjustments { settings.masks.remove(at: index) }
    }

    // MARK: Protect Skin Tones

    /// Brings the skin back inside Protect Skin Tones' limits once everything else is fitted:
    /// first by turning the skin's HSL bands (when Color is on), then, if that isn't enough, by
    /// pulling the sliders that color skin most (White Balance, Saturation, the skin's HSL bands,
    /// the grading wheels and the subject mask's color) back toward where they started.
    static func protect(_ skin: LookSkin, in settings: inout DevelopSettings, from base: DevelopSettings,
                        asShot: Double, options: LookMatchOptions, measure: (DevelopSettings) -> LookSample?) {
        guard let start = measure(settings) else {
            settings = base
            return
        }
        guard !skin.isWithin(start) else { return }
        // The bands skin's hue falls between, scaled so the main one moves fully.
        let shares = HSLAdjustment.weights(for: skin.hue < 0 ? skin.hue + 360 : skin.hue)
        let top = shares.max() ?? 0
        var bands: [(DevelopSettings.ColorBand, Double)] = []
        for (i, band) in DevelopSettings.ColorBand.allCases.enumerated() where top > 0 && shares[i] > 0.05 {
            bands.append((band, shares[i] / top))
        }
        func moved(_ s: DevelopSettings, _ kind: DevelopSettings.HSLChannel, by amount: Double) -> DevelopSettings {
            var out = s
            for (band, share) in bands {
                let parameter = DevelopSettings.Parameter.hsl(kind, band)
                out[parameter] = min(100, max(-100, s[parameter] + amount * share)).rounded()
            }
            return out
        }
        if options.color, settings.isOn(.hsl), !bands.isEmpty {
            let hueLimit = LookSkin.maxHueShift - 1, chromaLimit = LookSkin.maxChromaChange - 0.02
            for _ in 0..<3 {
                guard let now = measure(settings), let d = skin.drift(now) else { break }
                let excess = d.hue - min(hueLimit, max(-hueLimit, d.hue))
                guard abs(excess) > 0.5 else { break }
                let probe = excess > 0 ? -10.0 : 10.0
                guard let tried = measure(moved(settings, .hue, by: probe)), let t = skin.drift(tried) else { break }
                let slope = (t.hue - d.hue) / probe
                guard abs(slope) > 0.02 else { break }
                settings = moved(settings, .hue, by: min(60, max(-60, -excess / slope)))
            }
            for _ in 0..<3 {
                guard let now = measure(settings), let d = skin.drift(now) else { break }
                let goal = min(1 + chromaLimit, max(1 - chromaLimit, d.ratio))
                let excess = d.ratio - goal
                guard abs(excess) > 0.005 else { break }
                let probe = excess > 0 ? -10.0 : 10.0
                guard let tried = measure(moved(settings, .saturation, by: probe)), let t = skin.drift(tried) else { break }
                let slope = (t.ratio - d.ratio) / probe
                guard abs(slope) > 1e-4 else { break }
                settings = moved(settings, .saturation, by: min(60, max(-60, -excess / slope)))
            }
        }
        if let now = measure(settings), skin.isWithin(now) { return }

        // Pull back: the smallest pull (0 to 1) that brings the skin inside its limits.
        let matched = settings
        func pulled(_ t: Double) -> DevelopSettings {
            var out = matched
            let k = 1 - t
            let fromMired = 1e6 / (base.temperature ?? asShot), toMired = 1e6 / (matched.temperature ?? asShot)
            if matched.temperature != base.temperature {
                // Fully pulled back is the photo's own setting, As Shot included.
                out.temperature = k == 0 ? base.temperature : Optional((1e6 / (fromMired + (toMired - fromMired) * k)).rounded())
            }
            var parameters: [DevelopSettings.Parameter] = [.tint, .saturation, .vibrance]
            for (band, _) in bands { parameters += [.hsl(.hue, band), .hsl(.saturation, band)] }
            for region in LookMatch.gradeRegions { parameters.append(region.saturation) }
            for parameter in parameters where matched[parameter] != base[parameter] {
                let from = base[parameter]
                out[parameter] = k == 0 ? from : (from + (matched[parameter] - from) * k).rounded()
            }
            if let index = out.masks.firstIndex(where: { $0.name == LookMatch.subjectMaskName }) {
                let previous = base.masks.first { $0.id == out.masks[index].id }
                for parameter in [DevelopSettings.LocalParameter.temperature, .tint, .saturation] {
                    let from = previous?[parameter] ?? 0
                    let to = matched.masks[index][parameter]
                    if from != to { out.masks[index][parameter] = k == 0 ? from : (from + (to - from) * k).rounded() }
                }
            }
            return out
        }
        // If pulling back only color still leaves a shift, reduce the whole match. The
        // original render is the known safe endpoint, including Tone and any existing mask.
        let colorRestored = pulled(1)
        if let sample = measure(colorRestored), skin.isWithin(sample) {
            settings = strongestSafeMatch(from: colorRestored, skin: skin, measure: measure) { pulled(1 - $0) }
        } else {
            var match = LookMatch(base: base, matched: matched, asShotTemperature: asShot)
            match.subjectFitParameters = options.subjectFitParameters
            settings = strongestSafeMatch(from: base, skin: skin, measure: measure) { match.settings(strength: $0) }
        }
    }

    private static func strongestSafeMatch(from safe: DevelopSettings, skin: LookSkin,
                                           measure: (DevelopSettings) -> LookSample?,
                                           candidate: (Double) -> DevelopSettings) -> DevelopSettings {
        var low = 0.0, high = 1.0
        var best = safe
        for _ in 0..<6 {
            let strength = (low + high) / 2
            let settings = candidate(strength)
            if let sample = measure(settings), skin.isWithin(sample) {
                best = settings
                low = strength
            } else {
                high = strength
            }
        }
        return best
    }
}
