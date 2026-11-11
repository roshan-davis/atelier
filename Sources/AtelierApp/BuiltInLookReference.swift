import CoreGraphics
import Foundation
import AtelierCore

/// The built-in Match Look references: eight flat vector color studies (Rosh's drawings, SVG
/// files in Resources/Studies, drawn with `FlatSVG`). The same sRGB artwork supplies the picker
/// and the fit. Each portrait marks its person with `data-part` (skin, hair, clothes, features),
/// so Subject & Background and Show Skin use the drawing itself, not a search.
enum BuiltInLookReference: String, CaseIterable, Identifiable {
    case matrixPortrait, matrixCity, thronesPortrait, thronesLandscape
    case furyRoadPortrait, furyRoadScene, darkKnightPortrait, darkKnightCity

    enum Theme: String, CaseIterable, Identifiable {
        case matrix = "The Matrix"
        case thrones = "Game of Thrones"
        case furyRoad = "Mad Max: Fury Road"
        case darkKnight = "The Dark Knight"
        var id: Self { self }
    }

    enum Scene: String {
        case portrait = "Portrait"
        case urbanNight = "Urban Night"
        case winterLandscape = "Winter Landscape"
        case desertAction = "Desert Action"
    }

    var id: Self { self }

    var theme: Theme {
        switch self {
        case .matrixPortrait, .matrixCity: return .matrix
        case .thronesPortrait, .thronesLandscape: return .thrones
        case .furyRoadPortrait, .furyRoadScene: return .furyRoad
        case .darkKnightPortrait, .darkKnightCity: return .darkKnight
        }
    }

    var scene: Scene {
        switch self {
        case .matrixPortrait, .thronesPortrait, .furyRoadPortrait, .darkKnightPortrait: return .portrait
        case .matrixCity, .darkKnightCity: return .urbanNight
        case .thronesLandscape: return .winterLandscape
        case .furyRoadScene: return .desertAction
        }
    }

    var name: String { "\(theme.rawValue) — \(scene.rawValue)" }

    var palette: String {
        switch self {
        case .matrixPortrait: return "Olive skin, moss glass and graphite."
        case .matrixCity: return "Jade light, mint glow and near black."
        case .thronesPortrait: return "Pale warm skin, frost blue and slate."
        case .thronesLandscape: return "Snow white, ice blue and slate."
        case .furyRoadPortrait: return "Copper skin, teal sky and sand."
        case .furyRoadScene: return "Teal sky, burnt orange and rust."
        case .darkKnightPortrait: return "Amber skin, steel and ink."
        case .darkKnightCity: return "Navy slate, amber lights and ink."
        }
    }

    /// The main color-bearing parts of the composition, shown as a guide in the picker.
    var regions: String {
        switch scene {
        case .portrait: return "Face & Skin\nClothing · Background"
        case .urbanNight: return "Sky · Buildings · Street"
        case .winterLandscape: return "Sky · Snow · Ground"
        case .desertAction: return "Sky · Dust · Ground"
        }
    }

    var isPortrait: Bool { scene == .portrait }

    /// The drawing, read once from the app's resources.
    var drawing: FlatSVG? { Self.drawings[self] }

    private static let drawings: [BuiltInLookReference: FlatSVG] = {
        let bundle = AtelierResources.bundle
        return Dictionary(uniqueKeysWithValues: allCases.compactMap { reference -> (BuiltInLookReference, FlatSVG)? in
            let url = bundle.url(forResource: reference.rawValue, withExtension: "svg", subdirectory: "Studies")
                ?? bundle.url(forResource: reference.rawValue, withExtension: "svg")
            return url.flatMap { FlatSVG(url: $0) }.map { (reference, $0) }
        })
    }()

    /// Every portrait is drawn on the same 280 × 180 face, lit from the left: the skin samples
    /// (in the drawing's units) sit inside one flat tone each, clear of eyes, brows, nose and
    /// mouth. Shadows on the far cheek, midtones on the neck, highlights on the lit cheek.
    private static let skinSwatches = [CGRect(x: 146, y: 98, width: 8, height: 14),
                                       CGRect(x: 127, y: 132, width: 8, height: 14),
                                       CGRect(x: 125, y: 98, width: 9, height: 14)]
    /// The face, hair line to chin, in the drawing's units.
    private static let face = CGRect(x: 118, y: 56, width: 45, height: 72)
    /// The parts that make up the person.
    static let personParts: Set<String> = ["skin", "hair", "clothes", "features"]

    /// The skin samples of each portrait, 0 to 1 of the drawing: shadows, midtones and highlights.
    /// Wide studies have no skin sample.
    var skinToneRegions: [CGRect] {
        guard isPortrait, let drawing else { return [] }
        return Self.skinSwatches.map { unit($0, in: drawing.viewBox) }
    }

    /// The midtone sample alone.
    var skinRegions: [CGRect] {
        skinToneRegions.count == 3 ? [skinToneRegions[1]] : []
    }

    private func unit(_ r: CGRect, in box: CGRect) -> CGRect {
        CGRect(x: (r.minX - box.minX) / box.width, y: (r.minY - box.minY) / box.height,
               width: r.width / box.width, height: r.height / box.height)
    }

    /// What Subject & Background and Protect Skin Tones use from a portrait study, drawn rather
    /// than found by Vision: the person (the shapes marked skin, hair, clothes and features) and
    /// the face. Nil for wide studies.
    func features(for image: CGImage) -> LookReferenceFeatures? {
        guard isPortrait, let drawing, let mask = drawing.mask(parts: Self.personParts, width: 480) else { return nil }
        return LookReferenceFeatures(image: image, subjectMask: mask, faces: [unit(Self.face, in: drawing.viewBox)])
    }

    /// The drawn skin (white) for Show Skin, `width` pixels wide; all black for wide studies.
    func skinMask(width: Int) -> CGImage? {
        drawing?.mask(parts: ["skin"], width: width)
    }

    /// The study in sRGB, `width` pixels wide, with a faint grain (about ±2 levels) so brightness
    /// and color are continuous for the fit rather than a few spikes.
    func image(width: Int = 960) -> CGImage? {
        guard let flat = drawing?.image(width: width) else { return nil }
        return Self.grained(flat)
    }

    private static func grained(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = context.bytesPerRow
        let bytes = data.bindMemory(to: UInt8.self, capacity: row * height)
        for y in 0..<height {
            for x in 0..<width {
                var h = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
                h ^= h >> 13
                h = h &* 0x5bd1_e995
                h ^= h >> 15
                let noise = max(-2, min(2, Int(h & 3) - Int((h >> 2) & 3)))
                let offset = y * row + x * 4
                for channel in 0..<3 {
                    bytes[offset + channel] = UInt8(max(0, min(255, Int(bytes[offset + channel]) + noise)))
                }
            }
        }
        return context.makeImage()
    }
}
