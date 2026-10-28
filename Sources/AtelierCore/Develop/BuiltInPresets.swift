import Foundation

/// The built-in preset packs listed under the user's own groups in the Presets panel.
///
/// Each pack is made only from the Develop sliders, so it works on RAW, JPEG and HEIC alike. A
/// pack preset includes just the parts it changes plus Treatment (so color looks turn a B&W
/// photo back to color), and never White Balance, Profile, Lens Corrections, Transform, Crop
/// or Masks: warmth and coolness come from Color Grading. IDs are fixed so photos and import
/// settings that use a preset keep finding it.
extension DevelopPreset {
    /// The built-in packs, in panel order. The user's groups can't take these names.
    public static let builtInGroups = ["Atelier", "Film", "Black & White", "Portrait", "Landscape",
                                       "Vintage & Matte", "Cinematic"]

    public static func isBuiltInGroup(_ name: String) -> Bool {
        builtInGroups.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    public static let builtIn: [DevelopPreset] = atelierPack + filmPack + blackAndWhitePack + portraitPack
        + landscapePack + vintagePack + cinematicPack

    /// Pack `pack` (1 is Atelier), preset `index` within it. Atelier's IDs predate the packs.
    private static func look(_ pack: Int, _ index: Int, _ name: String, parts: Set<Part>? = nil,
                             _ configure: (inout DevelopSettings) -> Void) -> DevelopPreset {
        var settings = DevelopSettings()
        configure(&settings)
        let number = pack == 1 ? index : pack * 0x100 + index
        let id = UUID(uuidString: String(format: "6E2B6B5A-%04lX-4C5E-9A7E-0A7E11E5%04lX", number, number))!
        return DevelopPreset(id: id, name: name, group: builtInGroups[pack - 1],
                             parts: parts ?? Part.changed(in: settings).union([.treatment]),
                             settings: settings, isBuiltIn: true)
    }

    private static func curve(_ points: (Double, Double)...) -> [DevelopSettings.CurvePoint] {
        points.map { DevelopSettings.CurvePoint(x: $0.0, y: $0.1) }
    }

    private static func grade(_ s: inout DevelopSettings, _ region: DevelopSettings.GradeRegion, hue: Double, saturation: Double) {
        s[region.hue] = hue
        s[region.saturation] = saturation
    }

    /// The original five looks, unchanged.
    private static let atelierPack: [DevelopPreset] = [
        look(1, 1, "Clean Product", parts: Part.defaults) { s in
            s.highlights = -25
            s.shadows = 20
            s.whites = 10
            s.clarity = 5
            s.vibrance = 10
            s.sharpening = 50
        },
        look(1, 2, "Punchy", parts: Part.defaults) { s in
            s.contrast = 20
            s.clarity = 15
            s.vibrance = 25
            s.dehaze = 5
        },
        look(1, 3, "Soft Matte", parts: Part.defaults) { s in
            s.contrast = -10
            s.highlights = -15
            s.setPoints(curve((0, 0.08), (0.5, 0.52), (1, 0.95)), for: .rgb)
            s.saturation = -10
        },
        look(1, 4, "Warm Film", parts: Part.defaults) { s in
            grade(&s, .shadows, hue: 200, saturation: 15)
            grade(&s, .highlights, hue: 40, saturation: 20)
            s.contrast = 10
            s.grain = 20
            s.vignette = -15
        },
        look(1, 5, "Black & White", parts: Part.defaults) { s in
            s.saturation = -100
            s.contrast = 20
            s.clarity = 10
        },
    ]

    private static let filmPack: [DevelopPreset] = [
        look(2, 1, "Portrait 400") { s in
            s.contrast = -10
            s.highlights = -20
            s.shadows = 15
            s.vibrance = 5
            s.setPoints(curve((0, 0.04), (0.5, 0.51), (1, 0.97)), for: .rgb)
            s[.hsl(.saturation, .orange)] = -10
            s[.hsl(.luminance, .orange)] = 8
            grade(&s, .highlights, hue: 40, saturation: 12)
            grade(&s, .shadows, hue: 200, saturation: 6)
            s.grain = 15
            s.grainSize = 30
        },
        look(2, 2, "Gold 200") { s in
            s.contrast = 10
            s.vibrance = 15
            s[.hsl(.hue, .yellow)] = -8
            s[.hsl(.saturation, .yellow)] = 15
            s[.hsl(.saturation, .red)] = 10
            grade(&s, .global, hue: 45, saturation: 8)
            grade(&s, .highlights, hue: 45, saturation: 15)
            s.grain = 20
        },
        look(2, 3, "Vivid Slide") { s in
            s.contrast = 30
            s.blacks = -10
            s.clarity = 5
            s.vibrance = 15
            s.saturation = 15
            s.setPoints(curve((0, 0), (0.25, 0.2), (0.75, 0.82), (1, 1)), for: .rgb)
            s[.hsl(.saturation, .blue)] = 15
            s[.hsl(.luminance, .blue)] = -10
        },
        look(2, 4, "Tungsten 800T") { s in
            s.contrast = 5
            s.highlights = -15
            s.clarity = -10
            s[.hsl(.hue, .blue)] = -5
            grade(&s, .shadows, hue: 205, saturation: 25)
            grade(&s, .highlights, hue: 30, saturation: 15)
            s.grain = 30
            s.grainSize = 40
        },
        look(2, 5, "Expired") { s in
            s.contrast = -15
            s.saturation = -15
            s.setPoints(curve((0, 0.1), (0.5, 0.5), (1, 0.92)), for: .rgb)
            grade(&s, .shadows, hue: 150, saturation: 15)
            grade(&s, .highlights, hue: 320, saturation: 12)
            s.grain = 45
            s.grainSize = 45
            s.vignette = -10
        },
        look(2, 6, "Instant") { s in
            s.highlights = -20
            s.clarity = -5
            s.saturation = -5
            s.setPoints(curve((0, 0.12), (0.6, 0.62), (1, 0.9)), for: .rgb)
            grade(&s, .global, hue: 40, saturation: 10)
            s.vignette = -25
            s.vignetteMidpoint = 40
        },
    ]

    private static let blackAndWhitePack: [DevelopPreset] = [
        look(3, 1, "Neutral") { s in
            s.monochrome = true
            s.contrast = 10
        },
        look(3, 2, "High Contrast") { s in
            s.monochrome = true
            s.contrast = 40
            s.whites = 15
            s.blacks = -15
            s.clarity = 15
            s.setPoints(curve((0, 0), (0.25, 0.2), (0.75, 0.82), (1, 1)), for: .rgb)
            // A red filter: darker skies, brighter skin.
            s[.gray(.red)] = 15
            s[.gray(.orange)] = 10
            s[.gray(.blue)] = -30
        },
        look(3, 3, "Soft Matte B&W") { s in
            s.monochrome = true
            s.contrast = -15
            s.highlights = -10
            s.setPoints(curve((0, 0.1), (0.5, 0.52), (1, 0.94)), for: .rgb)
        },
        look(3, 4, "Push 400") { s in
            s.monochrome = true
            s.contrast = 30
            s.blacks = -10
            s.clarity = 20
            s.grain = 50
            s.grainSize = 45
        },
        look(3, 5, "Selenium") { s in
            s.monochrome = true
            s.contrast = 15
            grade(&s, .shadows, hue: 220, saturation: 20)
            grade(&s, .highlights, hue: 210, saturation: 5)
        },
        look(3, 6, "Sepia") { s in
            s.monochrome = true
            s.contrast = 5
            s.setPoints(curve((0, 0.04), (0.5, 0.51), (1, 0.97)), for: .rgb)
            grade(&s, .global, hue: 35, saturation: 25)
            grade(&s, .shadows, hue: 25, saturation: 15)
        },
    ]

    private static let portraitPack: [DevelopPreset] = [
        look(4, 1, "Natural Skin") { s in
            s.texture = -10
            s.vibrance = 5
            s[.hsl(.hue, .orange)] = 3
            s[.hsl(.saturation, .orange)] = -8
            s[.hsl(.luminance, .orange)] = 6
            grade(&s, .highlights, hue: 35, saturation: 6)
        },
        look(4, 2, "Soft Glow") { s in
            s.contrast = -5
            s.highlights = -10
            s.shadows = 10
            s.texture = -25
            s.clarity = -15
            grade(&s, .highlights, hue: 40, saturation: 8)
        },
        look(4, 3, "Warm Portrait") { s in
            s.contrast = 5
            s.shadows = 10
            s[.hsl(.saturation, .orange)] = 5
            grade(&s, .global, hue: 38, saturation: 12)
            grade(&s, .highlights, hue: 40, saturation: 10)
        },
        look(4, 4, "Clean Studio") { s in
            s.contrast = 10
            s.highlights = -10
            s.shadows = 15
            s.whites = 15
            s.texture = 5
            s.vibrance = 5
            s[.hsl(.saturation, .orange)] = -5
            s.sharpening = 40
        },
        look(4, 5, "Moody Portrait") { s in
            s.contrast = 15
            s.highlights = -25
            s.shadows = -10
            s.blacks = -10
            s.saturation = -15
            s[.hsl(.saturation, .orange)] = 5
            grade(&s, .shadows, hue: 210, saturation: 10)
            s.vignette = -20
        },
    ]

    private static let landscapePack: [DevelopPreset] = [
        look(5, 1, "Vivid Landscape") { s in
            s.contrast = 15
            s.clarity = 15
            s.dehaze = 10
            s.vibrance = 30
            s[.hsl(.saturation, .blue)] = 10
            s[.hsl(.saturation, .green)] = 10
            s.sharpening = 40
        },
        look(5, 2, "Golden Hour") { s in
            s.contrast = 5
            s.highlights = -15
            s.shadows = 10
            s[.hsl(.saturation, .orange)] = 15
            s[.hsl(.saturation, .yellow)] = 15
            s[.hsl(.luminance, .yellow)] = 10
            grade(&s, .highlights, hue: 40, saturation: 25)
            grade(&s, .global, hue: 35, saturation: 8)
        },
        look(5, 3, "Blue Hour") { s in
            s.contrast = 10
            s.highlights = -10
            s[.hsl(.saturation, .blue)] = 20
            s[.hsl(.luminance, .blue)] = -10
            grade(&s, .global, hue: 225, saturation: 12)
            grade(&s, .shadows, hue: 230, saturation: 15)
        },
        look(5, 4, "Deep Greens") { s in
            s.contrast = 10
            s.clarity = 10
            s[.hsl(.hue, .green)] = -5
            s[.hsl(.saturation, .green)] = 15
            s[.hsl(.luminance, .green)] = -15
            s[.hsl(.saturation, .yellow)] = 5
            s[.hsl(.luminance, .yellow)] = -10
        },
        look(5, 5, "Haze Cut") { s in
            s.contrast = 10
            s.highlights = -10
            s.blacks = -5
            s.clarity = 15
            s.dehaze = 25
            s.vibrance = 10
        },
    ]

    private static let vintagePack: [DevelopPreset] = [
        look(6, 1, "Faded Matte") { s in
            s.contrast = -10
            s.saturation = -20
            s.setPoints(curve((0, 0.14), (0.5, 0.5), (1, 0.95)), for: .rgb)
            grade(&s, .shadows, hue: 200, saturation: 8)
        },
        look(6, 2, "Seventies") { s in
            s.contrast = -15
            s.setPoints(curve((0, 0.08), (1, 0.94)), for: .rgb)
            s[.hsl(.saturation, .blue)] = -20
            grade(&s, .global, hue: 50, saturation: 15)
            grade(&s, .shadows, hue: 90, saturation: 10)
            s.grain = 25
        },
        look(6, 3, "Washed Teal") { s in
            s.contrast = -5
            s.saturation = -20
            s.setPoints(curve((0, 0.1), (1, 0.96)), for: .rgb)
            s[.hsl(.hue, .blue)] = -15
            s[.hsl(.saturation, .blue)] = -10
            grade(&s, .shadows, hue: 190, saturation: 25)
            grade(&s, .highlights, hue: 50, saturation: 8)
        },
        look(6, 4, "Cross Process") { s in
            s.contrast = 25
            s.saturation = 15
            s[.hsl(.saturation, .blue)] = -15
            grade(&s, .shadows, hue: 140, saturation: 25)
            grade(&s, .highlights, hue: 55, saturation: 25)
        },
        look(6, 5, "Dusty Pastel") { s in
            s.contrast = -20
            s.highlights = -20
            s.shadows = 25
            s.vibrance = 10
            s.saturation = -25
            s.setPoints(curve((0, 0.1), (0.5, 0.55), (1, 0.95)), for: .rgb)
            grade(&s, .highlights, hue: 330, saturation: 8)
        },
    ]

    private static let cinematicPack: [DevelopPreset] = [
        look(7, 1, "Teal & Orange") { s in
            s.contrast = 15
            s.saturation = -5
            s[.hsl(.saturation, .orange)] = 10
            s[.hsl(.hue, .blue)] = -15
            grade(&s, .shadows, hue: 195, saturation: 30)
            grade(&s, .highlights, hue: 35, saturation: 25)
        },
        look(7, 2, "Bleach Bypass") { s in
            s.contrast = 35
            s.highlights = -10
            s.blacks = -10
            s.clarity = 20
            s.saturation = -45
        },
        look(7, 3, "Noir") { s in
            s.monochrome = true
            s.contrast = 45
            s.highlights = -15
            s.blacks = -20
            s.clarity = 20
            s.vignette = -40
            s.vignetteMidpoint = 35
            s.grain = 20
        },
        look(7, 4, "Night City") { s in
            s.contrast = 15
            s.blacks = -10
            s.clarity = 10
            s[.hsl(.saturation, .blue)] = 15
            s[.hsl(.saturation, .magenta)] = 15
            grade(&s, .shadows, hue: 200, saturation: 25)
            grade(&s, .highlights, hue: 310, saturation: 15)
        },
        look(7, 5, "Warm Drama") { s in
            s.contrast = 25
            s.highlights = -25
            s.shadows = -10
            s.clarity = 15
            s.saturation = -10
            grade(&s, .global, hue: 35, saturation: 10)
            grade(&s, .shadows, hue: 25, saturation: 15)
            s.vignette = -20
        },
    ]
}
