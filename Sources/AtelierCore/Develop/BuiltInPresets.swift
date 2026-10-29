import Foundation

/// The built-in preset packs listed under the user's own groups in the Presets panel.
///
/// Each pack is made only from the Develop sliders, so it works on RAW, JPEG and HEIC alike. A
/// pack preset includes just the parts it changes plus Treatment (so color looks turn a B&W
/// photo back to color), and never Exposure, White Balance, Profile, Lens Corrections,
/// Transform, Crop or Masks: warmth and coolness come from Color Grading. IDs are fixed so
/// photos and import settings that use a preset keep finding it.
///
/// Tuned on Oct 29, 2026 against the current renderer (local Highlights/Shadows, Oklab Color
/// Grading, the new grain). Each look follows what the film stock or style is known for
/// (see the PRD's "Built-in presets retuned"); `Scripts/presets/preset_sheets.py` renders every
/// pack on test photos so changes can be judged before they ship.
extension DevelopPreset {
    /// The built-in packs, in panel order. The user's groups can't take these names.
    public static let builtInGroups = ["Atelier", "Film", "Black & White", "Portrait", "Landscape", "Street",
                                       "Cinematic", "Vintage & Matte"]

    public static func isBuiltInGroup(_ name: String) -> Bool {
        builtInGroups.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    public static let builtIn: [DevelopPreset] = atelierPack + filmPack + blackAndWhitePack + portraitPack
        + landscapePack + streetPack + cinematicPack + vintagePack

    /// Each pack's number in its presets' IDs. Panel order is `builtInGroups`; these never change.
    private static let packNumbers = ["Atelier": 1, "Film": 2, "Black & White": 3, "Portrait": 4, "Landscape": 5,
                                      "Vintage & Matte": 6, "Cinematic": 7, "Street": 8]

    /// Preset `index` of `group`. Atelier's IDs predate the packs. An index is never reused for
    /// another look, so a dropped preset's number stays retired.
    private static func look(_ group: String, _ index: Int, _ name: String,
                             _ configure: (inout DevelopSettings) -> Void) -> DevelopPreset {
        var settings = DevelopSettings()
        configure(&settings)
        let pack = packNumbers[group]!
        let number = pack == 1 ? index : pack * 0x100 + index
        let id = UUID(uuidString: String(format: "6E2B6B5A-%04lX-4C5E-9A7E-0A7E11E5%04lX", number, number))!
        return DevelopPreset(id: id, name: name, group: group, parts: Part.changed(in: settings).union([.treatment]),
                             settings: settings, isBuiltIn: true)
    }

    private static func curve(_ points: (Double, Double)...) -> [DevelopSettings.CurvePoint] {
        points.map { DevelopSettings.CurvePoint(x: $0.0, y: $0.1) }
    }

    private static func grade(_ s: inout DevelopSettings, _ region: DevelopSettings.GradeRegion, hue: Double,
                              saturation: Double, luminance: Double = 0) {
        s[region.hue] = hue
        s[region.saturation] = saturation
        s[region.luminance] = luminance
    }

    // Notes on this renderer, for tuning: Contrast ±100 moves the quarter tones by 0.08, so the
    // stronger looks shape tone with a point curve; Color Grading Saturation 10 adds 0.01 of
    // Oklab chroma, which is a clear but gentle tint; HSL Hue ±100 turns a band by 30°.

    /// The original five, kept by name and ID (Black & White is now a true B&W treatment).
    private static let atelierPack: [DevelopPreset] = [
        look("Atelier", 1, "Clean Product") { s in
            s.highlights = -30
            s.shadows = 25
            s.whites = 15
            s.blacks = -5
            s.texture = 10
            s.clarity = 5
            s.vibrance = 10
            s.sharpening = 50
        },
        look("Atelier", 2, "Punchy") { s in
            s.contrast = 30
            s.highlights = -15
            s.blacks = -8
            s.clarity = 15
            s.dehaze = 8
            s.vibrance = 25
            s.saturation = 5
        },
        look("Atelier", 3, "Soft Matte") { s in
            s.contrast = -15
            s.highlights = -15
            s.saturation = -12
            s.setPoints(curve((0, 0.08), (0.25, 0.28), (0.75, 0.76), (1, 0.95)), for: .rgb)
        },
        look("Atelier", 4, "Warm Film") { s in
            s.contrast = 15
            s.setPoints(curve((0, 0.04), (1, 0.97)), for: .rgb)
            grade(&s, .shadows, hue: 200, saturation: 12)
            grade(&s, .highlights, hue: 42, saturation: 22)
            grade(&s, .global, hue: 40, saturation: 6)
            s.grain = 22
            s.vignette = -15
        },
        look("Atelier", 5, "Black & White") { s in
            s.monochrome = true
            s.contrast = 25
            s.clarity = 10
        },
    ]

    /// Color film, by what each stock is known for. Names describe the look, never the brand.
    private static let filmPack: [DevelopPreset] = [
        // Portrait negative (Portra 400): soft contrast and roll-off, warm skin, olive greens,
        // slightly cyan blues, fine grain.
        look("Film", 1, "Portrait 400") { s in
            s.contrast = -10
            s.highlights = -25
            s.shadows = 15
            s.saturation = -8
            s.setPoints(curve((0, 0.05), (0.25, 0.27), (0.75, 0.76), (1, 0.97)), for: .rgb)
            s[.hsl(.hue, .orange)] = 3
            s[.hsl(.saturation, .orange)] = -5
            s[.hsl(.luminance, .orange)] = 8
            s[.hsl(.hue, .yellow)] = -10
            s[.hsl(.saturation, .yellow)] = -10
            s[.hsl(.hue, .green)] = -15
            s[.hsl(.saturation, .green)] = -20
            s[.hsl(.hue, .blue)] = -8
            s[.hsl(.saturation, .blue)] = -10
            grade(&s, .highlights, hue: 45, saturation: 10)
            grade(&s, .global, hue: 40, saturation: 5)
            s.grain = 15
        },
        // Consumer gold (Kodak Gold 200): warm and yellow, saturated reds, golden greens.
        look("Film", 2, "Gold 200") { s in
            s.contrast = 15
            s.highlights = -20
            s.shadows = 10
            s.vibrance = 15
            s.setPoints(curve((0, 0.03), (1, 0.98)), for: .rgb)
            s[.hsl(.saturation, .red)] = 10
            s[.hsl(.saturation, .orange)] = 10
            s[.hsl(.hue, .yellow)] = -10
            s[.hsl(.saturation, .yellow)] = 20
            s[.hsl(.hue, .green)] = -15
            s[.hsl(.saturation, .blue)] = -10
            grade(&s, .global, hue: 50, saturation: 10)
            grade(&s, .highlights, hue: 45, saturation: 15)
            grade(&s, .shadows, hue: 30, saturation: 6)
            s.grain = 25
        },
        // Pastel portrait negative (Fuji 400H): bright, low contrast, mint greens, cyan shadows,
        // a touch of pink in the highlights.
        look("Film", 7, "Pastel 400") { s in
            s.contrast = -15
            s.highlights = -20
            s.shadows = 25
            s.saturation = -10
            s.vibrance = 5
            s.setPoints(curve((0, 0.07), (0.5, 0.53), (1, 0.97)), for: .rgb)
            s[.hsl(.saturation, .orange)] = -5
            s[.hsl(.luminance, .orange)] = 10
            s[.hsl(.hue, .yellow)] = 10
            s[.hsl(.saturation, .yellow)] = -15
            s[.hsl(.hue, .green)] = 25
            s[.hsl(.saturation, .green)] = -20
            s[.hsl(.luminance, .green)] = 10
            s[.hsl(.hue, .blue)] = -10
            s[.hsl(.saturation, .blue)] = -10
            s[.hsl(.luminance, .blue)] = 5
            grade(&s, .shadows, hue: 175, saturation: 10)
            grade(&s, .highlights, hue: 330, saturation: 6)
            s.grain = 12
        },
        // Vivid fine-grain negative (Ektar 100): punchy, saturated reds and blues, clean grain.
        look("Film", 8, "Vivid 100") { s in
            s.contrast = 25
            s.highlights = -10
            s.blacks = -8
            s.vibrance = 20
            s.saturation = 10
            s[.hsl(.saturation, .red)] = 15
            s[.hsl(.saturation, .blue)] = 20
            s[.hsl(.luminance, .blue)] = -10
            s[.hsl(.saturation, .green)] = 10
            grade(&s, .highlights, hue: 45, saturation: 6)
            s.grain = 8
            s.grainSize = 15
        },
        // Slide film (Velvia, Ektachrome): deep blacks, rich blues and greens, no grain.
        look("Film", 3, "Vivid Slide") { s in
            s.contrast = 35
            s.blacks = -12
            s.vibrance = 20
            s.saturation = 15
            s.setPoints(curve((0, 0), (0.25, 0.21), (0.75, 0.8), (1, 1)), for: .rgb)
            s[.hsl(.saturation, .orange)] = -10
            s[.hsl(.saturation, .blue)] = 15
            s[.hsl(.luminance, .blue)] = -12
            s[.hsl(.saturation, .green)] = 10
            s[.hsl(.luminance, .green)] = -5
            grade(&s, .shadows, hue: 230, saturation: 5)
        },
        // Classic chrome slide (Kodachrome 64): contrast, deep reds and blues, warm cast.
        look("Film", 9, "Chrome 64") { s in
            s.contrast = 30
            s.highlights = -15
            s.shadows = -5
            s.blacks = -10
            s.clarity = 8
            s.saturation = 5
            s.setPoints(curve((0, 0.02), (0.25, 0.22), (0.75, 0.79), (1, 0.98)), for: .rgb)
            s[.hsl(.saturation, .red)] = 20
            s[.hsl(.luminance, .red)] = -8
            s[.hsl(.hue, .yellow)] = -10
            s[.hsl(.saturation, .yellow)] = 10
            s[.hsl(.hue, .green)] = -10
            s[.hsl(.saturation, .green)] = -10
            s[.hsl(.luminance, .green)] = -10
            s[.hsl(.saturation, .blue)] = 10
            s[.hsl(.luminance, .blue)] = -15
            grade(&s, .global, hue: 45, saturation: 6)
            grade(&s, .shadows, hue: 220, saturation: 6)
            s.grain = 10
        },
        // Tungsten cinema film in daylight (CineStill 800T): cool cast, teal shadows, warm
        // glowing highlights, soft and grainy.
        look("Film", 4, "Tungsten 800T") { s in
            s.contrast = 5
            s.highlights = -30
            s.shadows = 10
            s.clarity = -10
            s.saturation = -5
            s.setPoints(curve((0, 0.05), (1, 0.97)), for: .rgb)
            s[.hsl(.saturation, .red)] = 15
            s[.hsl(.hue, .blue)] = -10
            s[.hsl(.saturation, .blue)] = 10
            grade(&s, .global, hue: 210, saturation: 12)
            grade(&s, .shadows, hue: 195, saturation: 18)
            grade(&s, .highlights, hue: 25, saturation: 10)
            s.grain = 35
            s.grainSize = 40
            s.grainRoughness = 60
        },
        look("Film", 5, "Expired") { s in
            s.contrast = -20
            s.saturation = -20
            s.setPoints(curve((0, 0.12), (0.5, 0.5), (1, 0.9)), for: .rgb)
            grade(&s, .shadows, hue: 150, saturation: 18)
            grade(&s, .highlights, hue: 340, saturation: 12)
            grade(&s, .global, hue: 45, saturation: 6)
            s.grain = 45
            s.grainSize = 45
            s.vignette = -15
        },
        // Instant film: lifted blacks, soft highlights, teal greens, warm cast, dark corners.
        look("Film", 6, "Instant") { s in
            s.highlights = -25
            s.shadows = 10
            s.clarity = -10
            s.saturation = -10
            s.setPoints(curve((0, 0.12), (0.3, 0.33), (0.7, 0.72), (1, 0.9)), for: .rgb)
            s[.hsl(.hue, .green)] = 15
            s[.hsl(.hue, .blue)] = -10
            grade(&s, .shadows, hue: 190, saturation: 10)
            grade(&s, .highlights, hue: 45, saturation: 15)
            s.vignette = -25
            s.vignetteMidpoint = 40
        },
    ]

    /// Black & White treatment, with B&W Mix filters (positive brightens that color's gray).
    private static let blackAndWhitePack: [DevelopPreset] = [
        look("Black & White", 1, "Neutral") { s in
            s.monochrome = true
            s.contrast = 15
        },
        // Classic 400-speed film (HP5, Tri-X at box speed): moderate contrast, yellow filter
        // for a slightly darker sky, visible grain.
        look("Black & White", 7, "Classic 400") { s in
            s.monochrome = true
            s.contrast = 15
            s.highlights = -15
            s.shadows = 10
            s.clarity = 5
            s.setPoints(curve((0, 0.03), (1, 0.98)), for: .rgb)
            s[.gray(.orange)] = 5
            s[.gray(.yellow)] = 10
            s[.gray(.blue)] = -15
            s.grain = 25
            s.grainSize = 35
        },
        look("Black & White", 2, "High Contrast") { s in
            s.monochrome = true
            s.contrast = 45
            s.whites = 20
            s.blacks = -20
            s.clarity = 15
            s.setPoints(curve((0, 0), (0.25, 0.19), (0.75, 0.83), (1, 1)), for: .rgb)
            // A red filter: darker skies, brighter skin.
            s[.gray(.red)] = 20
            s[.gray(.orange)] = 15
            s[.gray(.yellow)] = 10
            s[.gray(.aqua)] = -20
            s[.gray(.blue)] = -40
        },
        // Pushed 400 film: hard contrast, deep shadows, coarse grain.
        look("Black & White", 4, "Push 400") { s in
            s.monochrome = true
            s.contrast = 40
            s.shadows = -10
            s.blacks = -15
            s.clarity = 25
            s.setPoints(curve((0, 0), (0.2, 0.15), (0.8, 0.86), (1, 1)), for: .rgb)
            s[.gray(.red)] = 10
            s[.gray(.orange)] = 10
            s[.gray(.blue)] = -20
            s.grain = 45
            s.grainSize = 45
            s.grainRoughness = 70
        },
        look("Black & White", 3, "Soft Matte B&W") { s in
            s.monochrome = true
            s.contrast = -15
            s.highlights = -10
            s.setPoints(curve((0, 0.1), (0.5, 0.52), (1, 0.94)), for: .rgb)
            s.grain = 10
        },
        // A deep red filter for landscapes: near-black skies, glowing foliage.
        look("Black & White", 8, "Dark Sky") { s in
            s.monochrome = true
            s.contrast = 25
            s.clarity = 10
            s[.gray(.red)] = 30
            s[.gray(.orange)] = 20
            s[.gray(.yellow)] = 30
            s[.gray(.green)] = 40
            s[.gray(.aqua)] = -40
            s[.gray(.blue)] = -70
        },
        look("Black & White", 5, "Selenium") { s in
            s.monochrome = true
            s.contrast = 20
            grade(&s, .shadows, hue: 225, saturation: 18)
            grade(&s, .highlights, hue: 210, saturation: 5)
        },
        look("Black & White", 6, "Sepia") { s in
            s.monochrome = true
            s.contrast = 5
            s.setPoints(curve((0, 0.04), (0.5, 0.51), (1, 0.97)), for: .rgb)
            grade(&s, .global, hue: 35, saturation: 28)
            grade(&s, .shadows, hue: 25, saturation: 15)
        },
    ]

    /// Skin first: orange is skin's hue band, so these move it gently and leave it smooth.
    private static let portraitPack: [DevelopPreset] = [
        look("Portrait", 1, "Natural Skin") { s in
            s.texture = -10
            s.clarity = -5
            s.vibrance = 5
            s[.hsl(.saturation, .red)] = -5
            s[.hsl(.hue, .orange)] = 3
            s[.hsl(.saturation, .orange)] = -8
            s[.hsl(.luminance, .orange)] = 8
            grade(&s, .highlights, hue: 35, saturation: 5)
        },
        // Wedding and lifestyle style: open shadows, bright mids, soft pastel color.
        look("Portrait", 6, "Bright & Airy") { s in
            s.contrast = -15
            s.highlights = -30
            s.shadows = 35
            s.whites = 20
            s.blacks = 10
            s.texture = -10
            s.saturation = -10
            s.vibrance = 5
            s.setPoints(curve((0, 0.05), (0.5, 0.56), (1, 1)), for: .rgb)
            s[.hsl(.saturation, .orange)] = -10
            s[.hsl(.luminance, .orange)] = 12
            s[.hsl(.saturation, .yellow)] = -20
            s[.hsl(.hue, .green)] = 20
            s[.hsl(.saturation, .green)] = -30
            s[.hsl(.luminance, .green)] = 15
            s[.hsl(.saturation, .blue)] = -15
            s[.hsl(.luminance, .blue)] = 10
            grade(&s, .highlights, hue: 40, saturation: 5)
            grade(&s, .shadows, hue: 200, saturation: 4)
        },
        look("Portrait", 2, "Soft Glow") { s in
            s.contrast = -10
            s.highlights = -15
            s.shadows = 10
            s.texture = -25
            s.clarity = -20
            s.setPoints(curve((0, 0.04), (1, 1)), for: .rgb)
            grade(&s, .highlights, hue: 40, saturation: 8)
        },
        look("Portrait", 3, "Warm Portrait") { s in
            s.contrast = 10
            s.shadows = 10
            s[.hsl(.saturation, .orange)] = 5
            s[.hsl(.luminance, .orange)] = 5
            grade(&s, .global, hue: 40, saturation: 6)
            grade(&s, .highlights, hue: 40, saturation: 10)
        },
        // For deeper skin tones: open shadows and warm, even midtones without a red cast.
        look("Portrait", 7, "Rich Skin") { s in
            s.contrast = 10
            s.highlights = -15
            s.shadows = 25
            s.texture = -5
            s.clarity = 5
            s[.hsl(.hue, .red)] = 5
            s[.hsl(.saturation, .red)] = -5
            s[.hsl(.saturation, .orange)] = 4
            grade(&s, .midtones, hue: 30, saturation: 6)
            grade(&s, .global, hue: 35, saturation: 4)
        },
        look("Portrait", 4, "Clean Studio") { s in
            s.contrast = 10
            s.highlights = -10
            s.shadows = 15
            s.whites = 15
            s.texture = 5
            s.vibrance = 5
            s[.hsl(.saturation, .orange)] = -5
        },
        look("Portrait", 5, "Moody Portrait") { s in
            s.contrast = 20
            s.highlights = -30
            s.shadows = -10
            s.blacks = -12
            s.saturation = -15
            s[.hsl(.saturation, .orange)] = 5
            s[.hsl(.saturation, .green)] = -30
            s[.hsl(.luminance, .green)] = -15
            s[.hsl(.saturation, .blue)] = -20
            grade(&s, .shadows, hue: 210, saturation: 12)
            grade(&s, .highlights, hue: 40, saturation: 6)
            s.vignette = -25
        },
    ]

    private static let landscapePack: [DevelopPreset] = [
        look("Landscape", 1, "Vivid Landscape") { s in
            s.contrast = 20
            s.highlights = -30
            s.shadows = 20
            s.clarity = 15
            s.dehaze = 10
            s.vibrance = 30
            s[.hsl(.saturation, .green)] = 10
            s[.hsl(.saturation, .aqua)] = 10
            s[.hsl(.saturation, .blue)] = 10
            s[.hsl(.luminance, .blue)] = -10
        },
        // Bright skies held back and darkened, clouds given shape.
        look("Landscape", 7, "Dramatic Sky") { s in
            s.contrast = 15
            s.highlights = -40
            s.shadows = 10
            s.whites = 10
            s.clarity = 20
            s.dehaze = 10
            s.vibrance = 10
            s[.hsl(.saturation, .aqua)] = 10
            s[.hsl(.luminance, .aqua)] = -15
            s[.hsl(.saturation, .blue)] = 15
            s[.hsl(.luminance, .blue)] = -25
            s.vignette = -15
        },
        look("Landscape", 2, "Golden Hour") { s in
            s.contrast = 10
            s.highlights = -20
            s.shadows = 15
            s.vibrance = 10
            s[.hsl(.saturation, .orange)] = 15
            s[.hsl(.saturation, .yellow)] = 15
            s[.hsl(.luminance, .yellow)] = 10
            grade(&s, .highlights, hue: 40, saturation: 25)
            grade(&s, .global, hue: 35, saturation: 10)
            grade(&s, .shadows, hue: 25, saturation: 6)
        },
        look("Landscape", 3, "Blue Hour") { s in
            s.contrast = 10
            s.highlights = -15
            s.shadows = 10
            s[.hsl(.saturation, .blue)] = 20
            s[.hsl(.luminance, .blue)] = -10
            grade(&s, .global, hue: 225, saturation: 12)
            grade(&s, .shadows, hue: 230, saturation: 15)
            grade(&s, .highlights, hue: 35, saturation: 8)
        },
        look("Landscape", 4, "Deep Greens") { s in
            s.contrast = 15
            s.clarity = 10
            s[.hsl(.hue, .yellow)] = -10
            s[.hsl(.saturation, .yellow)] = -5
            s[.hsl(.luminance, .yellow)] = -15
            s[.hsl(.hue, .green)] = 10
            s[.hsl(.saturation, .green)] = 10
            s[.hsl(.luminance, .green)] = -25
        },
        // Leaves toward orange and gold.
        look("Landscape", 6, "Autumn Colors") { s in
            s.contrast = 15
            s.vibrance = 15
            s[.hsl(.saturation, .red)] = 15
            s[.hsl(.saturation, .orange)] = 25
            s[.hsl(.luminance, .orange)] = -5
            s[.hsl(.hue, .yellow)] = -15
            s[.hsl(.saturation, .yellow)] = 20
            s[.hsl(.luminance, .yellow)] = -5
            s[.hsl(.hue, .green)] = -40
            s[.hsl(.saturation, .green)] = -10
            grade(&s, .highlights, hue: 40, saturation: 10)
        },
        look("Landscape", 5, "Haze Cut") { s in
            s.contrast = 10
            s.highlights = -15
            s.blacks = -5
            s.clarity = 15
            s.dehaze = 30
            s.vibrance = 10
        },
    ]

    private static let streetPack: [DevelopPreset] = [
        // Muted documentary color (Fujifilm's Classic Chrome): hard tone, low saturation,
        // cyan blues, olive greens.
        look("Street", 1, "Muted Chrome") { s in
            s.contrast = 15
            s.highlights = -20
            s.shadows = -5
            s.saturation = -20
            s.setPoints(curve((0, 0.03), (0.25, 0.22), (0.75, 0.78), (1, 0.97)), for: .rgb)
            s[.hsl(.saturation, .red)] = 5
            s[.hsl(.luminance, .red)] = -5
            s[.hsl(.saturation, .yellow)] = -15
            s[.hsl(.hue, .green)] = -15
            s[.hsl(.saturation, .green)] = -25
            s[.hsl(.hue, .blue)] = -10
            s[.hsl(.saturation, .blue)] = -20
            grade(&s, .shadows, hue: 200, saturation: 8)
            grade(&s, .highlights, hue: 40, saturation: 5)
            s.grain = 10
        },
        look("Street", 2, "Gritty") { s in
            s.contrast = 35
            s.blacks = -10
            s.texture = 15
            s.clarity = 30
            s.dehaze = 5
            s.saturation = -35
            s.vignette = -20
            s.grain = 20
        },
        // Strong sun and deep shadows with bold color, in the manner of the Magnum colorists.
        look("Street", 3, "Hard Light") { s in
            s.contrast = 40
            s.shadows = -20
            s.blacks = -15
            s.saturation = 10
            s[.hsl(.saturation, .red)] = 15
            s[.hsl(.saturation, .yellow)] = 10
            s[.hsl(.luminance, .blue)] = -10
            grade(&s, .highlights, hue: 45, saturation: 6)
        },
        look("Street", 4, "Urban Cool") { s in
            s.contrast = 20
            s.highlights = -15
            s.saturation = -15
            s[.hsl(.saturation, .orange)] = 5
            s[.hsl(.saturation, .blue)] = 10
            grade(&s, .global, hue: 215, saturation: 8)
            grade(&s, .shadows, hue: 200, saturation: 15)
            s.vignette = -10
        },
        // Everyday consumer negative (Superia): green-leaning shadows, warm highlights, grain.
        look("Street", 5, "Daylight Negative") { s in
            s.contrast = 10
            s.vibrance = 10
            s.setPoints(curve((0, 0.04), (0.25, 0.25), (1, 0.98)), for: .rgb)
            s[.hsl(.hue, .green)] = 10
            s[.hsl(.saturation, .green)] = 5
            grade(&s, .shadows, hue: 160, saturation: 10)
            grade(&s, .highlights, hue: 40, saturation: 8)
            s.grain = 25
        },
    ]

    private static let cinematicPack: [DevelopPreset] = [
        look("Cinematic", 1, "Teal & Orange") { s in
            s.contrast = 20
            s.highlights = -15
            s.saturation = -5
            s[.hsl(.hue, .orange)] = -3
            s[.hsl(.saturation, .orange)] = 10
            s[.hsl(.hue, .yellow)] = -15
            s[.hsl(.hue, .green)] = 40
            s[.hsl(.saturation, .green)] = -20
            s[.hsl(.hue, .blue)] = -15
            // Teal shadows against orange skin; the balance leans toward the shadows so whites
            // stay clean.
            grade(&s, .shadows, hue: 190, saturation: 35)
            grade(&s, .midtones, hue: 32, saturation: 12)
            grade(&s, .highlights, hue: 40, saturation: 10)
            s[.gradeBalance] = -20
        },
        // The popular dark, desaturated look: soft blacks, muted greens, warm skin.
        look("Cinematic", 6, "Dark & Moody") { s in
            s.contrast = 10
            s.highlights = -30
            s.shadows = -15
            s.saturation = -15
            s.setPoints(curve((0, 0.06), (0.25, 0.2), (0.75, 0.74), (1, 0.94)), for: .rgb)
            s[.hsl(.saturation, .orange)] = 5
            s[.hsl(.hue, .green)] = -20
            s[.hsl(.saturation, .green)] = -40
            s[.hsl(.luminance, .green)] = -20
            s[.hsl(.saturation, .blue)] = -25
            s[.hsl(.luminance, .blue)] = -15
            grade(&s, .shadows, hue: 200, saturation: 10)
            grade(&s, .highlights, hue: 35, saturation: 8)
            s.vignette = -20
        },
        look("Cinematic", 2, "Bleach Bypass") { s in
            s.contrast = 40
            s.highlights = -10
            s.blacks = -10
            s.clarity = 20
            s.saturation = -45
            s.setPoints(curve((0, 0), (0.25, 0.2), (0.75, 0.81), (1, 1)), for: .rgb)
        },
        look("Cinematic", 3, "Noir") { s in
            s.monochrome = true
            s.contrast = 45
            s.highlights = -15
            s.blacks = -20
            s.clarity = 20
            s.setPoints(curve((0, 0), (0.25, 0.19), (0.75, 0.8), (1, 1)), for: .rgb)
            s.vignette = -40
            s.vignetteMidpoint = 35
            s.grain = 20
        },
        look("Cinematic", 4, "Night City") { s in
            s.contrast = 15
            s.highlights = -15
            s.blacks = -10
            s.clarity = 10
            s.vibrance = 10
            s[.hsl(.saturation, .blue)] = 15
            s[.hsl(.saturation, .purple)] = 10
            s[.hsl(.saturation, .magenta)] = 15
            grade(&s, .shadows, hue: 205, saturation: 25)
            grade(&s, .highlights, hue: 310, saturation: 8)
        },
        look("Cinematic", 5, "Warm Drama") { s in
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

    private static let vintagePack: [DevelopPreset] = [
        look("Vintage & Matte", 1, "Faded Matte") { s in
            s.contrast = -10
            s.saturation = -20
            s.setPoints(curve((0, 0.14), (0.5, 0.5), (1, 0.95)), for: .rgb)
            grade(&s, .shadows, hue: 200, saturation: 8)
            grade(&s, .highlights, hue: 45, saturation: 5)
        },
        look("Vintage & Matte", 2, "Seventies") { s in
            s.contrast = -15
            s.setPoints(curve((0, 0.08), (1, 0.94)), for: .rgb)
            s[.hsl(.saturation, .blue)] = -25
            s[.hsl(.hue, .green)] = -20
            grade(&s, .global, hue: 50, saturation: 15)
            grade(&s, .shadows, hue: 90, saturation: 10)
            s.grain = 25
        },
        look("Vintage & Matte", 3, "Washed Teal") { s in
            s.contrast = -5
            s.saturation = -20
            s.setPoints(curve((0, 0.1), (1, 0.96)), for: .rgb)
            s[.hsl(.hue, .blue)] = -15
            s[.hsl(.saturation, .blue)] = -10
            grade(&s, .shadows, hue: 190, saturation: 25)
            grade(&s, .highlights, hue: 50, saturation: 8)
        },
        look("Vintage & Matte", 4, "Cross Process") { s in
            s.contrast = 25
            s.saturation = 15
            s[.hsl(.saturation, .blue)] = -15
            grade(&s, .shadows, hue: 140, saturation: 25)
            grade(&s, .highlights, hue: 55, saturation: 25)
        },
        look("Vintage & Matte", 5, "Dusty Pastel") { s in
            s.contrast = -20
            s.highlights = -20
            s.shadows = 25
            s.vibrance = 10
            s.saturation = -25
            s.setPoints(curve((0, 0.1), (0.5, 0.55), (1, 0.95)), for: .rgb)
            grade(&s, .highlights, hue: 330, saturation: 8)
            grade(&s, .shadows, hue: 190, saturation: 6)
        },
    ]
}
