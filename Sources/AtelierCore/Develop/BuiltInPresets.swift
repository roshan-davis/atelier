import Foundation

/// The built-in preset packs listed under the user's own groups in the Presets panel.
///
/// Each pack is made only from the Develop sliders, so it works on RAW, JPEG and HEIC alike. A
/// pack preset includes just the parts it changes plus Treatment (so color looks turn a B&W
/// photo back to color), and never Exposure, White Balance, Profile, Lens Corrections,
/// Transform, Crop or Masks: warmth and coolness come from Color Grading and per-channel RGB
/// curves. IDs are fixed so photos and import settings that use a preset keep finding it;
/// dropped presets retire their numbers.
///
/// Tuned on Oct 29, 2026 against the current renderer (local Highlights/Shadows, Oklab Color
/// Grading, per-channel RGB curves, Tone Curve regions and the new grain). Each look is
/// distinct — redundant filler presets were retired in favor of high-impact looks tailored to
/// wildlife, fine-art reproduction, landscapes, street and cinema. `Scripts/presets/preset_sheets.py`
/// renders every pack on test photos so changes can be judged before they ship.
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
    // looks shape tone with a point curve, region sliders (curveShadows/Darks/Lights/Highlights)
    // and per-channel RGB curves (red/green/blue) for film toe/shoulder crossover; Color Grading
    // Saturation 10 adds 0.01 of Oklab chroma, and Luminance lifts or deepens tonal ranges.

    /// Everyday essentials: product, artwork reproduction, wildlife/detail punch, warm film and B&W.
    private static let atelierPack: [DevelopPreset] = [
        // Crisp whites, open shadows and clean micro-contrast for product & studio work.
        look("Atelier", 1, "Clean Product") { s in
            s.contrast = 15
            s.highlights = -35
            s.shadows = 30
            s.whites = 22
            s.blacks = -8
            s.texture = 12
            s.clarity = 8
            s.vibrance = 12
            s[.curveLights] = 10
            s[.curveDarks] = -5
            s.sharpening = 50
        },
        // True paper whites and pigment fidelity without hue shifts, for watercolor and artwork.
        look("Atelier", 6, "Fine Art & Pigments") { s in
            s.contrast = 18
            s.highlights = -18
            s.shadows = 18
            s.whites = 26
            s.blacks = -12
            s.texture = 16
            s.clarity = 10
            s.vibrance = 22
            s.saturation = 5
            s[.curveLights] = 12
            s[.curveDarks] = -6
            s.sharpening = 45
            s[.sharpenDetail] = 35
        },
        // Bold tonal bite, anchored blacks and rich color separation.
        look("Atelier", 2, "Punchy") { s in
            s.contrast = 38
            s.highlights = -25
            s.shadows = 10
            s.whites = 15
            s.blacks = -18
            s.texture = 10
            s.clarity = 22
            s.dehaze = 10
            s.vibrance = 30
            s.saturation = 6
            s.setPoints(curve((0, 0), (0.22, 0.17), (0.78, 0.84), (1, 1)), for: .rgb)
        },
        // Everyday analog warmth with red/blue channel crossover and cyan-tinted shadow toe.
        look("Atelier", 4, "Warm Film") { s in
            s.contrast = 20
            s.highlights = -20
            s.shadows = 15
            s.vibrance = 15
            s.setPoints(curve((0, 0.03), (0.25, 0.23), (0.75, 0.80), (1, 0.98)), for: .rgb)
            s.setPoints(curve((0, 0.01), (0.5, 0.53), (1, 0.99)), for: .red)
            s.setPoints(curve((0, 0.04), (0.5, 0.48), (1, 0.93)), for: .blue)
            grade(&s, .shadows, hue: 200, saturation: 16, luminance: 4)
            grade(&s, .midtones, hue: 38, saturation: 10, luminance: 4)
            grade(&s, .highlights, hue: 42, saturation: 24, luminance: -4)
            s.grain = 20
            s.vignette = -15
        },
        // Luminous everyday monochrome with a yellow-orange filter mix and deep blacks.
        look("Atelier", 5, "Black & White") { s in
            s.monochrome = true
            s.contrast = 32
            s.highlights = -20
            s.shadows = 10
            s.whites = 18
            s.blacks = -16
            s.texture = 10
            s.clarity = 16
            s.setPoints(curve((0, 0), (0.22, 0.17), (0.78, 0.84), (1, 1)), for: .rgb)
            s[.gray(.red)] = 12
            s[.gray(.orange)] = 18
            s[.gray(.yellow)] = 15
            s[.gray(.green)] = -10
            s[.gray(.aqua)] = -15
            s[.gray(.blue)] = -30
        },
    ]

    /// Color film, by what each stock is known for, using per-channel RGB curves for authentic
    /// emulsion toe and shoulder crossover. Names describe the look, never the brand.
    private static let filmPack: [DevelopPreset] = [
        // Portrait negative (Portra 400): creamy highlight roll-off, golden-peach skin, celadon
        // greens, and subtle blue-channel toe warmth without a gray veil.
        look("Film", 1, "Portrait 400") { s in
            s.contrast = 12
            s.highlights = -24
            s.shadows = 20
            s.whites = 10
            s.blacks = -6
            s.vibrance = 16
            s.setPoints(curve((0, 0.02), (0.25, 0.24), (0.55, 0.59), (0.85, 0.87), (1, 0.98)), for: .rgb)
            s.setPoints(curve((0, 0.01), (0.5, 0.52), (1, 0.99)), for: .red)
            s.setPoints(curve((0, 0.03), (0.5, 0.49), (1, 0.94)), for: .blue)
            s[.hsl(.hue, .red)] = 6
            s[.hsl(.hue, .orange)] = 4
            s[.hsl(.saturation, .orange)] = 8
            s[.hsl(.luminance, .orange)] = 12
            s[.hsl(.hue, .yellow)] = -12
            s[.hsl(.saturation, .yellow)] = -6
            s[.hsl(.hue, .green)] = -18
            s[.hsl(.saturation, .green)] = -16
            s[.hsl(.hue, .blue)] = -10
            s[.hsl(.saturation, .blue)] = -6
            grade(&s, .shadows, hue: 210, saturation: 8, luminance: 4)
            grade(&s, .midtones, hue: 36, saturation: 10, luminance: 4)
            grade(&s, .highlights, hue: 44, saturation: 18, luminance: -4)
            s.grain = 14
            s.grainSize = 22
        },
        // Consumer gold (Kodak Gold 200): nostalgic golden-amber cast, punchy reds, warm shadows.
        look("Film", 2, "Gold 200") { s in
            s.contrast = 24
            s.highlights = -22
            s.shadows = 12
            s.whites = 10
            s.blacks = -10
            s.vibrance = 22
            s.saturation = 6
            s.setPoints(curve((0, 0.02), (0.25, 0.22), (0.75, 0.80), (1, 0.98)), for: .rgb)
            s.setPoints(curve((0, 0.02), (0.5, 0.53), (1, 1)), for: .red)
            s.setPoints(curve((0, 0.01), (0.5, 0.46), (1, 0.91)), for: .blue)
            s[.hsl(.saturation, .red)] = 16
            s[.hsl(.saturation, .orange)] = 16
            s[.hsl(.luminance, .orange)] = 6
            s[.hsl(.hue, .yellow)] = -14
            s[.hsl(.saturation, .yellow)] = 25
            s[.hsl(.hue, .green)] = -18
            s[.hsl(.saturation, .blue)] = -8
            grade(&s, .global, hue: 46, saturation: 12)
            grade(&s, .midtones, hue: 42, saturation: 14, luminance: 4)
            grade(&s, .highlights, hue: 45, saturation: 22)
            grade(&s, .shadows, hue: 28, saturation: 10)
            s.grain = 22
        },
        // Pastel portrait negative (Fuji Pro 400H): airy overexposed brightness, mint-emerald
        // greens, cool cyan shadows and delicate peach skin.
        look("Film", 7, "Pastel 400") { s in
            s.contrast = 5
            s.highlights = -18
            s.shadows = 32
            s.whites = 20
            s.vibrance = 14
            s.saturation = -4
            s[.curveLights] = 14
            s.setPoints(curve((0, 0.03), (0.3, 0.34), (0.65, 0.71), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0.02), (0.5, 0.53), (1, 0.99)), for: .green)
            s.setPoints(curve((0, 0.04), (0.5, 0.52), (1, 0.97)), for: .blue)
            s[.hsl(.hue, .orange)] = 4
            s[.hsl(.luminance, .orange)] = 14
            s[.hsl(.hue, .yellow)] = 15
            s[.hsl(.saturation, .yellow)] = -12
            s[.hsl(.hue, .green)] = 30
            s[.hsl(.saturation, .green)] = -15
            s[.hsl(.luminance, .green)] = 12
            s[.hsl(.hue, .aqua)] = 10
            s[.hsl(.hue, .blue)] = -14
            s[.hsl(.luminance, .blue)] = 8
            grade(&s, .shadows, hue: 180, saturation: 14, luminance: 8)
            grade(&s, .midtones, hue: 165, saturation: 6, luminance: 6)
            grade(&s, .highlights, hue: 345, saturation: 10, luminance: 6)
            s.grain = 12
        },
        // Vivid fine-grain negative (Ektar 100): high micro-contrast, deep blacks, rich reds and
        // cyan-shifted skies.
        look("Film", 8, "Vivid 100") { s in
            s.contrast = 32
            s.highlights = -18
            s.shadows = -6
            s.whites = 12
            s.blacks = -14
            s.clarity = 10
            s.vibrance = 26
            s.saturation = 14
            s.setPoints(curve((0, 0), (0.22, 0.17), (0.78, 0.84), (1, 1)), for: .rgb)
            s.setPoints(curve((0, 0), (0.5, 0.53), (1, 1)), for: .red)
            s[.hsl(.hue, .red)] = 5
            s[.hsl(.saturation, .red)] = 22
            s[.hsl(.saturation, .orange)] = 14
            s[.hsl(.hue, .yellow)] = -10
            s[.hsl(.hue, .green)] = 10
            s[.hsl(.saturation, .green)] = 12
            s[.hsl(.hue, .aqua)] = 15
            s[.hsl(.hue, .blue)] = -12
            s[.hsl(.saturation, .blue)] = 24
            s[.hsl(.luminance, .blue)] = -14
            grade(&s, .shadows, hue: 225, saturation: 10, luminance: -6)
            grade(&s, .highlights, hue: 42, saturation: 12)
            s.grain = 8
            s.grainSize = 15
        },
        // Slide film (Velvia 50): ink-deep blacks, dramatic emerald greens, cobalt skies and
        // glowing warm highlights.
        look("Film", 3, "Vivid Slide") { s in
            s.contrast = 42
            s.highlights = -15
            s.shadows = -10
            s.whites = 14
            s.blacks = -18
            s.clarity = 12
            s.vibrance = 28
            s.saturation = 20
            s.setPoints(curve((0, 0), (0.22, 0.15), (0.5, 0.50), (0.78, 0.85), (1, 1)), for: .rgb)
            s[.hsl(.saturation, .red)] = 18
            s[.hsl(.saturation, .orange)] = -6
            s[.hsl(.hue, .green)] = 8
            s[.hsl(.saturation, .green)] = 24
            s[.hsl(.luminance, .green)] = -10
            s[.hsl(.saturation, .aqua)] = 20
            s[.hsl(.hue, .blue)] = 6
            s[.hsl(.saturation, .blue)] = 25
            s[.hsl(.luminance, .blue)] = -18
            s[.hsl(.saturation, .purple)] = 15
            grade(&s, .shadows, hue: 245, saturation: 12, luminance: -10)
            grade(&s, .highlights, hue: 38, saturation: 10)
        },
        // Classic chrome slide (Kodachrome 64): archival editorial contrast, deep crimson reds,
        // royal blues and warm golden-ochre midtones.
        look("Film", 9, "Chrome 64") { s in
            s.contrast = 36
            s.highlights = -18
            s.shadows = -8
            s.whites = 12
            s.blacks = -14
            s.texture = 8
            s.clarity = 14
            s.saturation = 8
            s.setPoints(curve((0, 0.01), (0.22, 0.17), (0.5, 0.51), (0.78, 0.83), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0), (0.5, 0.52), (1, 0.99)), for: .red)
            s.setPoints(curve((0, 0.02), (0.5, 0.48), (1, 0.95)), for: .blue)
            s[.hsl(.hue, .red)] = -4
            s[.hsl(.saturation, .red)] = 28
            s[.hsl(.luminance, .red)] = -10
            s[.hsl(.hue, .orange)] = -5
            s[.hsl(.saturation, .orange)] = 12
            s[.hsl(.hue, .yellow)] = -15
            s[.hsl(.saturation, .yellow)] = 18
            s[.hsl(.hue, .green)] = -18
            s[.hsl(.saturation, .green)] = -18
            s[.hsl(.luminance, .green)] = -14
            s[.hsl(.hue, .blue)] = -6
            s[.hsl(.saturation, .blue)] = 16
            s[.hsl(.luminance, .blue)] = -18
            grade(&s, .global, hue: 44, saturation: 8)
            grade(&s, .midtones, hue: 40, saturation: 10)
            grade(&s, .shadows, hue: 220, saturation: 10, luminance: -6)
            s.grain = 12
        },
        // Tungsten cinema film (CineStill 800T): electric cyan-teal cast, halation-inspired
        // warm red-amber highlights, and rich cinema grain.
        look("Film", 4, "Tungsten 800T") { s in
            s.contrast = 22
            s.highlights = -20
            s.shadows = 8
            s.whites = 18
            s.blacks = -12
            s.clarity = -8
            s.vibrance = 15
            s.setPoints(curve((0, 0.02), (0.22, 0.18), (0.78, 0.83), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0), (0.65, 0.64), (1, 1)), for: .red)
            s.setPoints(curve((0, 0.05), (0.4, 0.45), (1, 0.95)), for: .blue)
            s[.hsl(.hue, .red)] = 8
            s[.hsl(.saturation, .red)] = 25
            s[.hsl(.luminance, .red)] = 10
            s[.hsl(.saturation, .orange)] = 18
            s[.hsl(.luminance, .orange)] = 10
            s[.hsl(.hue, .green)] = 25
            s[.hsl(.hue, .aqua)] = 10
            s[.hsl(.saturation, .aqua)] = 20
            s[.hsl(.hue, .blue)] = -14
            s[.hsl(.saturation, .blue)] = 18
            grade(&s, .shadows, hue: 200, saturation: 28, luminance: -6)
            grade(&s, .midtones, hue: 205, saturation: 14)
            grade(&s, .highlights, hue: 18, saturation: 26, luminance: 10)
            s[.gradeBalance] = -15
            s.grain = 30
            s.grainSize = 35
            s.grainRoughness = 55
        },
        // Instant film (Polaroid SX-70): creamy border-warm highlights, emerald-teal shadows,
        // soft micro-contrast and optical corner falloff.
        look("Film", 6, "Instant") { s in
            s.contrast = 15
            s.highlights = -22
            s.shadows = 14
            s.whites = 8
            s.texture = -8
            s.clarity = -10
            s.vibrance = 12
            s.setPoints(curve((0, 0.06), (0.25, 0.24), (0.75, 0.80), (1, 0.95)), for: .rgb)
            s.setPoints(curve((0, 0.02), (0.5, 0.53), (1, 0.98)), for: .red)
            s.setPoints(curve((0, 0.08), (0.5, 0.48), (1, 0.88)), for: .blue)
            s[.hsl(.saturation, .red)] = 12
            s[.hsl(.hue, .yellow)] = -12
            s[.hsl(.hue, .green)] = 22
            s[.hsl(.saturation, .green)] = -10
            s[.hsl(.hue, .blue)] = -16
            grade(&s, .shadows, hue: 185, saturation: 18)
            grade(&s, .midtones, hue: 42, saturation: 12)
            grade(&s, .highlights, hue: 48, saturation: 24)
            s.vignette = -28
            s.vignetteMidpoint = 40
            s.grain = 16
        },
    ]

    /// Black & White treatment, with B&W Mix filters and darkroom toning.
    private static let blackAndWhitePack: [DevelopPreset] = [
        // Darkroom fiber print (Ansel Adams / Ilford Multigrade): deep Dmax blacks, luminous
        // paper whites and a subtle cool-shadow / warm-highlight gallery tone.
        look("Black & White", 9, "Silver Gelatin") { s in
            s.monochrome = true
            s.contrast = 28
            s.highlights = -22
            s.shadows = 14
            s.whites = 24
            s.blacks = -18
            s.texture = 12
            s.clarity = 18
            s[.curveLights] = 12
            s[.curveDarks] = -10
            s.setPoints(curve((0, 0), (0.22, 0.17), (0.78, 0.84), (1, 1)), for: .rgb)
            s[.gray(.red)] = 10
            s[.gray(.orange)] = 16
            s[.gray(.yellow)] = 20
            s[.gray(.green)] = 8
            s[.gray(.aqua)] = -18
            s[.gray(.blue)] = -35
            grade(&s, .shadows, hue: 220, saturation: 5, luminance: -6)
            grade(&s, .highlights, hue: 46, saturation: 6, luminance: 4)
        },
        // Classic 400-speed film (Tri-X / HP5): crisp S-curve toe, yellow filter sky separation
        // and authentic silver grain.
        look("Black & White", 7, "Classic 400") { s in
            s.monochrome = true
            s.contrast = 28
            s.highlights = -18
            s.shadows = 12
            s.whites = 14
            s.blacks = -12
            s.texture = 12
            s.clarity = 12
            s.setPoints(curve((0, 0.02), (0.22, 0.18), (0.78, 0.83), (1, 0.99)), for: .rgb)
            s[.gray(.red)] = 10
            s[.gray(.orange)] = 14
            s[.gray(.yellow)] = 18
            s[.gray(.green)] = -6
            s[.gray(.blue)] = -25
            s.grain = 26
            s.grainSize = 32
        },
        // Red filter monochrome: dramatic dark skies, sculpted clouds and bright skin tones.
        look("Black & White", 2, "High Contrast") { s in
            s.monochrome = true
            s.contrast = 48
            s.highlights = -15
            s.whites = 22
            s.blacks = -22
            s.clarity = 20
            s.setPoints(curve((0, 0), (0.24, 0.17), (0.76, 0.85), (1, 1)), for: .rgb)
            s[.gray(.red)] = 25
            s[.gray(.orange)] = 20
            s[.gray(.yellow)] = 15
            s[.gray(.aqua)] = -25
            s[.gray(.blue)] = -48
        },
        // Pushed 400 film (1600 ISO): gritty street contrast, crushed shadow toe and coarse grain.
        look("Black & White", 4, "Push 400") { s in
            s.monochrome = true
            s.contrast = 45
            s.highlights = -10
            s.shadows = -14
            s.whites = 18
            s.blacks = -20
            s.texture = 18
            s.clarity = 28
            s.setPoints(curve((0, 0), (0.20, 0.13), (0.80, 0.88), (1, 1)), for: .rgb)
            s[.gray(.red)] = 14
            s[.gray(.orange)] = 14
            s[.gray(.blue)] = -25
            s.grain = 45
            s.grainSize = 44
            s.grainRoughness = 68
        },
        // Deep red landscape filter: near-black skies and glowing sunlit foliage.
        look("Black & White", 8, "Dark Sky") { s in
            s.monochrome = true
            s.contrast = 32
            s.highlights = -20
            s.whites = 18
            s.blacks = -16
            s.clarity = 18
            s.dehaze = 12
            s[.gray(.red)] = 32
            s[.gray(.orange)] = 24
            s[.gray(.yellow)] = 35
            s[.gray(.green)] = 42
            s[.gray(.aqua)] = -48
            s[.gray(.blue)] = -78
        },
        // Aerochrome / Wood effect infrared B&W: foliage turns snowy white against jet-black skies.
        look("Black & White", 10, "Infrared Glow") { s in
            s.monochrome = true
            s.contrast = 30
            s.highlights = -12
            s.shadows = 15
            s.whites = 26
            s.blacks = -22
            s.texture = -10
            s.clarity = -16
            s.dehaze = 15
            s.setPoints(curve((0, 0), (0.22, 0.16), (0.72, 0.84), (1, 1)), for: .rgb)
            s[.gray(.red)] = 25
            s[.gray(.orange)] = 20
            s[.gray(.yellow)] = 85
            s[.gray(.green)] = 95
            s[.gray(.aqua)] = -65
            s[.gray(.blue)] = -85
            s.vignette = -18
        },
        // Cool archival selenium print toning with deep slate shadows and crisp highlights.
        look("Black & White", 5, "Selenium") { s in
            s.monochrome = true
            s.contrast = 28
            s.highlights = -15
            s.whites = 16
            s.blacks = -14
            s.clarity = 12
            s.setPoints(curve((0, 0), (0.25, 0.21), (0.75, 0.81), (1, 1)), for: .rgb)
            s[.gray(.orange)] = 12
            s[.gray(.yellow)] = 10
            s[.gray(.blue)] = -20
            grade(&s, .shadows, hue: 225, saturation: 20, luminance: -8)
            grade(&s, .midtones, hue: 220, saturation: 10)
            grade(&s, .highlights, hue: 210, saturation: 5, luminance: 4)
        },
        // Warm platinum-palladium & antique sepia print with rich cocoa shadows and clean paper highlights.
        look("Black & White", 6, "Sepia") { s in
            s.monochrome = true
            s.contrast = 24
            s.highlights = -18
            s.shadows = 12
            s.whites = 12
            s.blacks = -10
            s.setPoints(curve((0, 0.02), (0.25, 0.21), (0.75, 0.81), (1, 0.99)), for: .rgb)
            s[.gray(.orange)] = 15
            s[.gray(.yellow)] = 12
            s[.gray(.blue)] = -18
            grade(&s, .shadows, hue: 26, saturation: 22, luminance: -4)
            grade(&s, .midtones, hue: 36, saturation: 28)
            grade(&s, .highlights, hue: 44, saturation: 14, luminance: 4)
        },
    ]

    /// Skin first: orange and red are skin's hue bands, shaped gently while surrounding colors
    /// and tonal contrast set the mood.
    private static let portraitPack: [DevelopPreset] = [
        // Flattering editorial skin: smooth texture, softened redness, luminous peach tones and
        // gentle midtone lift.
        look("Portrait", 1, "Natural Skin") { s in
            s.contrast = 12
            s.highlights = -20
            s.shadows = 18
            s.whites = 12
            s.blacks = -6
            s.texture = -14
            s.clarity = -6
            s.vibrance = 12
            s[.curveLights] = 8
            s[.hsl(.hue, .red)] = 6
            s[.hsl(.saturation, .red)] = -10
            s[.hsl(.luminance, .red)] = 6
            s[.hsl(.hue, .orange)] = 4
            s[.hsl(.saturation, .orange)] = -6
            s[.hsl(.luminance, .orange)] = 12
            s[.hsl(.saturation, .green)] = -12
            grade(&s, .midtones, hue: 34, saturation: 6, luminance: 4)
            grade(&s, .highlights, hue: 40, saturation: 10)
        },
        // Luminous wedding & lifestyle look: open shadows, glowing upper-midtones, mint-sage
        // foliage and creamy skin.
        look("Portrait", 6, "Bright & Airy") { s in
            s.contrast = -8
            s.highlights = -22
            s.shadows = 38
            s.whites = 24
            s.blacks = 8
            s.texture = -12
            s.clarity = -6
            s.vibrance = 14
            s.saturation = -6
            s[.curveLights] = 16
            s.setPoints(curve((0, 0.03), (0.3, 0.35), (0.65, 0.72), (1, 1)), for: .rgb)
            s[.hsl(.hue, .red)] = 5
            s[.hsl(.saturation, .orange)] = -6
            s[.hsl(.luminance, .orange)] = 16
            s[.hsl(.hue, .yellow)] = 10
            s[.hsl(.saturation, .yellow)] = -22
            s[.hsl(.luminance, .yellow)] = 10
            s[.hsl(.hue, .green)] = 24
            s[.hsl(.saturation, .green)] = -32
            s[.hsl(.luminance, .green)] = 16
            s[.hsl(.saturation, .blue)] = -16
            s[.hsl(.luminance, .blue)] = 12
            grade(&s, .shadows, hue: 195, saturation: 8, luminance: 8)
            grade(&s, .highlights, hue: 38, saturation: 12, luminance: 8)
        },
        // Dreamy highlight bloom and halation-softened skin with warm golden rim light.
        look("Portrait", 2, "Soft Glow") { s in
            s.contrast = 8
            s.highlights = -12
            s.shadows = 16
            s.whites = 18
            s.texture = -20
            s.clarity = -18
            s.vibrance = 10
            s[.curveHighlights] = 12
            s[.curveLights] = 8
            s.setPoints(curve((0, 0.03), (0.5, 0.54), (1, 1)), for: .rgb)
            s[.hsl(.luminance, .orange)] = 10
            grade(&s, .shadows, hue: 25, saturation: 8)
            grade(&s, .midtones, hue: 36, saturation: 10, luminance: 6)
            grade(&s, .highlights, hue: 42, saturation: 18, luminance: 6)
        },
        // Sun-kissed golden portrait: rich amber midtones, warm catchlights and olive-shifted
        // background greens.
        look("Portrait", 3, "Warm Portrait") { s in
            s.contrast = 20
            s.highlights = -20
            s.shadows = 18
            s.whites = 12
            s.blacks = -8
            s.texture = -8
            s.vibrance = 15
            s.setPoints(curve((0, 0.02), (0.25, 0.23), (0.75, 0.79), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0), (0.5, 0.52), (1, 1)), for: .red)
            s.setPoints(curve((0, 0.02), (0.5, 0.47), (1, 0.94)), for: .blue)
            s[.hsl(.hue, .red)] = 5
            s[.hsl(.saturation, .orange)] = 10
            s[.hsl(.luminance, .orange)] = 10
            s[.hsl(.hue, .yellow)] = -12
            s[.hsl(.hue, .green)] = -18
            s[.hsl(.saturation, .green)] = -20
            grade(&s, .global, hue: 38, saturation: 10)
            grade(&s, .midtones, hue: 35, saturation: 14, luminance: 4)
            grade(&s, .highlights, hue: 42, saturation: 18)
        },
        // Tuned for deeper skin tones: open shadow detail, golden-bronze specular highlights,
        // and even warm midtones without a red or magenta cast.
        look("Portrait", 7, "Rich Skin") { s in
            s.contrast = 16
            s.highlights = -18
            s.shadows = 32
            s.whites = 14
            s.blacks = -8
            s.texture = -8
            s.clarity = 8
            s.vibrance = 14
            s[.curveLights] = 12
            s[.curveShadows] = 8
            s[.hsl(.hue, .red)] = 8
            s[.hsl(.saturation, .red)] = -8
            s[.hsl(.luminance, .red)] = 8
            s[.hsl(.hue, .orange)] = 4
            s[.hsl(.saturation, .orange)] = 8
            s[.hsl(.luminance, .orange)] = 12
            s[.hsl(.saturation, .yellow)] = 10
            s[.hsl(.luminance, .yellow)] = 8
            s[.hsl(.saturation, .magenta)] = -15
            grade(&s, .shadows, hue: 32, saturation: 8, luminance: 6)
            grade(&s, .midtones, hue: 36, saturation: 14, luminance: 6)
            grade(&s, .highlights, hue: 44, saturation: 12)
        },
        // Fashion & studio strobe look: crisp three-dimensional contrast, clean neutral backdrop
        // whites and controlled skin saturation.
        look("Portrait", 4, "Clean Studio") { s in
            s.contrast = 24
            s.highlights = -18
            s.shadows = 15
            s.whites = 22
            s.blacks = -14
            s.texture = 6
            s.clarity = 10
            s.vibrance = 10
            s[.curveLights] = 10
            s[.curveDarks] = -8
            s[.hsl(.hue, .red)] = 4
            s[.hsl(.saturation, .orange)] = -6
            s[.hsl(.luminance, .orange)] = 8
            s[.hsl(.saturation, .blue)] = -15
            s.sharpening = 45
        },
        // Editorial chiaroscuro portrait: deep sculpted shadows, muted forest/background colors,
        // and luminous skin standing out from the frame.
        look("Portrait", 5, "Moody Portrait") { s in
            s.contrast = 28
            s.highlights = -32
            s.shadows = -12
            s.whites = 8
            s.blacks = -16
            s.clarity = 10
            s.saturation = -14
            s.setPoints(curve((0, 0.01), (0.22, 0.16), (0.78, 0.80), (1, 0.96)), for: .rgb)
            s[.hsl(.hue, .red)] = 4
            s[.hsl(.saturation, .orange)] = 12
            s[.hsl(.luminance, .orange)] = 12
            s[.hsl(.hue, .yellow)] = -15
            s[.hsl(.saturation, .yellow)] = -25
            s[.hsl(.hue, .green)] = -20
            s[.hsl(.saturation, .green)] = -45
            s[.hsl(.luminance, .green)] = -20
            s[.hsl(.saturation, .blue)] = -30
            s[.hsl(.luminance, .blue)] = -15
            grade(&s, .shadows, hue: 210, saturation: 16, luminance: -10)
            grade(&s, .midtones, hue: 34, saturation: 8)
            grade(&s, .highlights, hue: 40, saturation: 12)
            s.vignette = -28
            s.vignetteMidpoint = 42
        },
    ]

    /// Nature, forests, skies and wildlife.
    private static let landscapePack: [DevelopPreset] = [
        // Balanced dynamic range, rich foliage & skies, and crisp detail without halos.
        look("Landscape", 1, "Vivid Landscape") { s in
            s.contrast = 28
            s.highlights = -35
            s.shadows = 25
            s.whites = 16
            s.blacks = -12
            s.texture = 12
            s.clarity = 18
            s.dehaze = 12
            s.vibrance = 32
            s.saturation = 6
            s.setPoints(curve((0, 0), (0.22, 0.18), (0.78, 0.83), (1, 1)), for: .rgb)
            s[.hsl(.hue, .green)] = -6
            s[.hsl(.saturation, .green)] = 14
            s[.hsl(.saturation, .aqua)] = 14
            s[.hsl(.saturation, .blue)] = 18
            s[.hsl(.luminance, .blue)] = -14
            grade(&s, .highlights, hue: 42, saturation: 8)
        },
        // Recover cloud structure and deepen blue skies while keeping the foreground open.
        look("Landscape", 7, "Dramatic Sky") { s in
            s.contrast = 26
            s.highlights = -48
            s.shadows = 18
            s.whites = 14
            s.blacks = -12
            s.texture = 10
            s.clarity = 24
            s.dehaze = 16
            s.vibrance = 18
            s[.curveHighlights] = -12
            s[.curveLights] = 8
            s[.hsl(.saturation, .orange)] = 12
            s[.hsl(.saturation, .aqua)] = 16
            s[.hsl(.luminance, .aqua)] = -20
            s[.hsl(.saturation, .blue)] = 22
            s[.hsl(.luminance, .blue)] = -32
            grade(&s, .shadows, hue: 215, saturation: 10, luminance: -6)
            grade(&s, .highlights, hue: 38, saturation: 10)
            s.vignette = -18
        },
        // Low-angle sunset warmth: glowing amber-gold light across midtones and highlights
        // against deep violet-blue shadows.
        look("Landscape", 2, "Golden Hour") { s in
            s.contrast = 22
            s.highlights = -25
            s.shadows = 20
            s.whites = 16
            s.blacks = -10
            s.clarity = 10
            s.vibrance = 22
            s.setPoints(curve((0, 0.01), (0.25, 0.22), (0.75, 0.81), (1, 1)), for: .rgb)
            s.setPoints(curve((0, 0), (0.5, 0.54), (1, 1)), for: .red)
            s.setPoints(curve((0, 0.02), (0.5, 0.45), (1, 0.90)), for: .blue)
            s[.hsl(.saturation, .red)] = 16
            s[.hsl(.hue, .orange)] = -4
            s[.hsl(.saturation, .orange)] = 24
            s[.hsl(.luminance, .orange)] = 8
            s[.hsl(.hue, .yellow)] = -12
            s[.hsl(.saturation, .yellow)] = 22
            s[.hsl(.luminance, .yellow)] = 12
            s[.hsl(.hue, .green)] = -18
            grade(&s, .shadows, hue: 265, saturation: 12, luminance: -4)
            grade(&s, .midtones, hue: 36, saturation: 20, luminance: 6)
            grade(&s, .highlights, hue: 42, saturation: 30, luminance: 6)
        },
        // Twilight serenity: cobalt-indigo atmosphere with warm distant horizon / cabin lights.
        look("Landscape", 3, "Blue Hour") { s in
            s.contrast = 22
            s.highlights = -22
            s.shadows = 15
            s.whites = 12
            s.blacks = -12
            s.clarity = 12
            s.vibrance = 18
            s.setPoints(curve((0, 0), (0.24, 0.19), (0.76, 0.82), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0.03), (0.5, 0.55), (1, 1)), for: .blue)
            s[.hsl(.saturation, .orange)] = 20
            s[.hsl(.luminance, .orange)] = 10
            s[.hsl(.saturation, .aqua)] = 15
            s[.hsl(.hue, .blue)] = -6
            s[.hsl(.saturation, .blue)] = 25
            s[.hsl(.luminance, .blue)] = -12
            s[.hsl(.saturation, .purple)] = 15
            grade(&s, .shadows, hue: 230, saturation: 24, luminance: -8)
            grade(&s, .midtones, hue: 222, saturation: 18)
            grade(&s, .highlights, hue: 36, saturation: 16, luminance: 6)
        },
        // Redwood & forest light: rich emerald-pine foliage paired with glowing golden sunbeams
        // (avoids turning forest shadows muddy).
        look("Landscape", 4, "Deep Greens") { s in
            s.contrast = 24
            s.highlights = -20
            s.shadows = 12
            s.whites = 18
            s.blacks = -14
            s.texture = 10
            s.clarity = 16
            s.dehaze = 10
            s.vibrance = 15
            s[.curveLights] = 10
            s[.curveDarks] = -8
            s[.hsl(.saturation, .orange)] = 12
            s[.hsl(.hue, .yellow)] = -12
            s[.hsl(.saturation, .yellow)] = -8
            s[.hsl(.luminance, .yellow)] = 8
            s[.hsl(.hue, .green)] = 14
            s[.hsl(.saturation, .green)] = 12
            s[.hsl(.luminance, .green)] = -18
            s[.hsl(.saturation, .aqua)] = 15
            grade(&s, .shadows, hue: 165, saturation: 14, luminance: -8)
            grade(&s, .midtones, hue: 145, saturation: 8)
            grade(&s, .highlights, hue: 46, saturation: 20, luminance: 8)
        },
        // Turn summer/early-fall foliage toward copper, amber and crimson while keeping skies deep.
        look("Landscape", 6, "Autumn Colors") { s in
            s.contrast = 24
            s.highlights = -20
            s.shadows = 15
            s.whites = 12
            s.blacks = -10
            s.clarity = 14
            s.vibrance = 22
            s[.hsl(.saturation, .red)] = 22
            s[.hsl(.hue, .orange)] = -6
            s[.hsl(.saturation, .orange)] = 30
            s[.hsl(.luminance, .orange)] = 6
            s[.hsl(.hue, .yellow)] = -22
            s[.hsl(.saturation, .yellow)] = 28
            s[.hsl(.luminance, .yellow)] = -4
            s[.hsl(.hue, .green)] = -55
            s[.hsl(.saturation, .green)] = -15
            s[.hsl(.luminance, .green)] = -10
            s[.hsl(.saturation, .blue)] = 15
            s[.hsl(.luminance, .blue)] = -14
            grade(&s, .shadows, hue: 215, saturation: 10, luminance: -4)
            grade(&s, .midtones, hue: 34, saturation: 12)
            grade(&s, .highlights, hue: 40, saturation: 16)
        },
        // Wildlife, birds & action: feather/fur micro-contrast, eye/beak golden pop, and clean
        // background separation.
        look("Landscape", 8, "Wildlife & Detail") { s in
            s.contrast = 24
            s.highlights = -28
            s.shadows = 22
            s.whites = 16
            s.blacks = -14
            s.texture = 28
            s.clarity = 20
            s.dehaze = 8
            s.vibrance = 22
            s[.curveLights] = 8
            s[.curveDarks] = -8
            s[.hsl(.saturation, .orange)] = 16
            s[.hsl(.luminance, .orange)] = 8
            s[.hsl(.saturation, .yellow)] = 18
            s[.hsl(.luminance, .yellow)] = 8
            s[.hsl(.saturation, .green)] = -15
            s[.hsl(.luminance, .green)] = -10
            s[.hsl(.saturation, .blue)] = -8
            s[.hsl(.luminance, .blue)] = -10
            s.sharpening = 60
            s[.sharpenDetail] = 45
            s[.sharpenMasking] = 30
            s.luminanceNoise = 15
            s.vignette = -14
        },
    ]

    /// Documentary, photojournalism and urban light.
    private static let streetPack: [DevelopPreset] = [
        // Fujifilm Classic Chrome emulation: firm shadow bite, restrained saturation, cyan skies
        // and olive greens.
        look("Street", 1, "Muted Chrome") { s in
            s.contrast = 26
            s.highlights = -24
            s.shadows = -8
            s.whites = 10
            s.blacks = -14
            s.texture = 10
            s.clarity = 14
            s.saturation = -18
            s.vibrance = 8
            s.setPoints(curve((0, 0.02), (0.22, 0.18), (0.78, 0.81), (1, 0.98)), for: .rgb)
            s.setPoints(curve((0, 0.03), (0.5, 0.49), (1, 0.96)), for: .blue)
            s[.hsl(.hue, .red)] = 5
            s[.hsl(.saturation, .red)] = 12
            s[.hsl(.luminance, .red)] = -6
            s[.hsl(.saturation, .orange)] = 6
            s[.hsl(.hue, .yellow)] = -12
            s[.hsl(.saturation, .yellow)] = -18
            s[.hsl(.hue, .green)] = -20
            s[.hsl(.saturation, .green)] = -30
            s[.hsl(.luminance, .green)] = -12
            s[.hsl(.hue, .blue)] = -14
            s[.hsl(.saturation, .blue)] = -22
            s[.hsl(.luminance, .blue)] = -10
            grade(&s, .shadows, hue: 200, saturation: 12, luminance: -8)
            grade(&s, .midtones, hue: 40, saturation: 6)
            grade(&s, .highlights, hue: 42, saturation: 10)
            s.grain = 12
        },
        // High-microcontrast reportage look with desaturated steel tones and heavy texture.
        look("Street", 2, "Gritty") { s in
            s.contrast = 38
            s.highlights = -20
            s.shadows = -10
            s.whites = 12
            s.blacks = -16
            s.texture = 22
            s.clarity = 34
            s.dehaze = 10
            s.saturation = -35
            s.setPoints(curve((0, 0), (0.22, 0.16), (0.78, 0.84), (1, 1)), for: .rgb)
            grade(&s, .shadows, hue: 210, saturation: 10, luminance: -8)
            s.vignette = -22
            s.grain = 22
        },
        // Magnum / Alex Webb colorist style: deep dramatic shadows against saturated primary reds,
        // yellows and blues in direct sun.
        look("Street", 3, "Hard Light") { s in
            s.contrast = 44
            s.highlights = -18
            s.shadows = -24
            s.whites = 16
            s.blacks = -20
            s.clarity = 14
            s.vibrance = 18
            s.saturation = 12
            s.setPoints(curve((0, 0), (0.22, 0.14), (0.55, 0.52), (0.80, 0.85), (1, 1)), for: .rgb)
            s[.hsl(.saturation, .red)] = 24
            s[.hsl(.luminance, .red)] = -6
            s[.hsl(.saturation, .orange)] = 15
            s[.hsl(.saturation, .yellow)] = 20
            s[.hsl(.saturation, .blue)] = 18
            s[.hsl(.luminance, .blue)] = -18
            grade(&s, .shadows, hue: 225, saturation: 10, luminance: -12)
            grade(&s, .highlights, hue: 44, saturation: 12)
        },
        // Leica / Classic Neg street look: punchy contrast, copper-orange skin & brick, and
        // deep cyan-slate asphalt shadows.
        look("Street", 6, "Classic Neg") { s in
            s.contrast = 30
            s.highlights = -20
            s.shadows = -12
            s.whites = 14
            s.blacks = -14
            s.texture = 16
            s.clarity = 18
            s.saturation = -8
            s.vibrance = 14
            s.setPoints(curve((0, 0.02), (0.22, 0.16), (0.55, 0.54), (0.80, 0.84), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0), (0.5, 0.53), (1, 1)), for: .red)
            s.setPoints(curve((0, 0.04), (0.5, 0.47), (1, 0.95)), for: .blue)
            s[.hsl(.hue, .red)] = 8
            s[.hsl(.saturation, .red)] = 20
            s[.hsl(.hue, .orange)] = -4
            s[.hsl(.saturation, .orange)] = 16
            s[.hsl(.hue, .green)] = 15
            s[.hsl(.saturation, .green)] = -25
            s[.hsl(.luminance, .green)] = -14
            s[.hsl(.hue, .blue)] = -12
            s[.hsl(.saturation, .blue)] = -10
            s[.hsl(.luminance, .blue)] = -12
            grade(&s, .shadows, hue: 192, saturation: 20, luminance: -8)
            grade(&s, .midtones, hue: 30, saturation: 10)
            grade(&s, .highlights, hue: 42, saturation: 14)
            s.grain = 18
        },
        // Everyday consumer 400 negative (Fuji Superia 400): fourth-layer emerald-cyan shadow
        // tint, punchy magenta-reds and lively grain.
        look("Street", 5, "Daylight Negative") { s in
            s.contrast = 22
            s.highlights = -18
            s.shadows = 12
            s.whites = 12
            s.blacks = -8
            s.vibrance = 18
            s.setPoints(curve((0, 0.03), (0.25, 0.23), (0.75, 0.80), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0.04), (0.5, 0.52), (1, 0.98)), for: .green)
            s[.hsl(.hue, .red)] = -6
            s[.hsl(.saturation, .red)] = 18
            s[.hsl(.hue, .green)] = 16
            s[.hsl(.saturation, .green)] = 12
            s[.hsl(.hue, .blue)] = -10
            s[.hsl(.saturation, .blue)] = 10
            grade(&s, .shadows, hue: 162, saturation: 18, luminance: 4)
            grade(&s, .midtones, hue: 40, saturation: 6)
            grade(&s, .highlights, hue: 42, saturation: 14)
            s.grain = 24
            s.grainSize = 28
        },
    ]

    /// Widescreen cinema color grading and dramatic lighting.
    private static let cinematicPack: [DevelopPreset] = [
        // Blockbuster complementary color contrast: deep cyan-teal shadows against warm golden
        // skin tones and crisp highlights.
        look("Cinematic", 1, "Teal & Orange") { s in
            s.contrast = 28
            s.highlights = -22
            s.shadows = 8
            s.whites = 12
            s.blacks = -14
            s.clarity = 12
            s.vibrance = 12
            s.saturation = -5
            s.setPoints(curve((0, 0.01), (0.23, 0.18), (0.77, 0.83), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0), (0.5, 0.52), (1, 1)), for: .red)
            s.setPoints(curve((0, 0.04), (0.5, 0.48), (1, 0.94)), for: .blue)
            s[.hsl(.hue, .red)] = 8
            s[.hsl(.saturation, .red)] = 12
            s[.hsl(.hue, .orange)] = -2
            s[.hsl(.saturation, .orange)] = 20
            s[.hsl(.luminance, .orange)] = 8
            s[.hsl(.hue, .yellow)] = -22
            s[.hsl(.saturation, .yellow)] = -15
            s[.hsl(.hue, .green)] = 55
            s[.hsl(.saturation, .green)] = -30
            s[.hsl(.hue, .aqua)] = 10
            s[.hsl(.saturation, .aqua)] = 20
            s[.hsl(.hue, .blue)] = -18
            s[.hsl(.saturation, .blue)] = 15
            s[.hsl(.luminance, .blue)] = -12
            grade(&s, .shadows, hue: 194, saturation: 38, luminance: -10)
            grade(&s, .midtones, hue: 32, saturation: 16, luminance: 4)
            grade(&s, .highlights, hue: 40, saturation: 18, luminance: 6)
            s[.gradeBalance] = -18
        },
        // Rich, brooding atmosphere: deep anchored blacks (never washed-out gray), desaturated
        // pine greens, and warm glowing subjects.
        look("Cinematic", 6, "Dark & Moody") { s in
            s.contrast = 28
            s.highlights = -35
            s.shadows = -18
            s.whites = -4
            s.blacks = -16
            s.texture = 8
            s.clarity = 14
            s.vibrance = 10
            s.saturation = -18
            s.setPoints(curve((0, 0.01), (0.20, 0.13), (0.55, 0.50), (0.85, 0.80), (1, 0.94)), for: .rgb)
            s[.hsl(.saturation, .red)] = 10
            s[.hsl(.saturation, .orange)] = 16
            s[.hsl(.luminance, .orange)] = 10
            s[.hsl(.hue, .yellow)] = -20
            s[.hsl(.saturation, .yellow)] = -30
            s[.hsl(.hue, .green)] = -25
            s[.hsl(.saturation, .green)] = -55
            s[.hsl(.luminance, .green)] = -28
            s[.hsl(.saturation, .aqua)] = -35
            s[.hsl(.saturation, .blue)] = -35
            s[.hsl(.luminance, .blue)] = -22
            grade(&s, .shadows, hue: 205, saturation: 18, luminance: -15)
            grade(&s, .midtones, hue: 34, saturation: 10, luminance: -5)
            grade(&s, .highlights, hue: 40, saturation: 14, luminance: -4)
            s.vignette = -26
            s.vignetteMidpoint = 40
        },
        // Silver-retention lab process: metallic highlights, steep contrast and gritty muted color.
        look("Cinematic", 2, "Bleach Bypass") { s in
            s.contrast = 45
            s.highlights = -15
            s.shadows = -12
            s.whites = 15
            s.blacks = -16
            s.texture = 15
            s.clarity = 28
            s.saturation = -48
            s.setPoints(curve((0, 0), (0.24, 0.17), (0.76, 0.84), (1, 1)), for: .rgb)
            grade(&s, .shadows, hue: 200, saturation: 10, luminance: -8)
            grade(&s, .highlights, hue: 48, saturation: 8)
            s.grain = 18
        },
        // High-contrast chiaroscuro B&W with deep spotlight vignetting and silver highlights.
        look("Cinematic", 3, "Noir") { s in
            s.monochrome = true
            s.contrast = 48
            s.highlights = -12
            s.shadows = -18
            s.whites = 20
            s.blacks = -24
            s.clarity = 24
            s.setPoints(curve((0, 0), (0.24, 0.16), (0.76, 0.84), (1, 1)), for: .rgb)
            s[.gray(.red)] = 15
            s[.gray(.orange)] = 20
            s[.gray(.blue)] = -35
            s.vignette = -42
            s.vignetteMidpoint = 35
            s.grain = 22
        },
        // Neon-lit cyberpunk & urban night: controlled sign highlights, electric cyan and magenta
        // neon reflections, and deep midnight shadows.
        look("Cinematic", 4, "Night City") { s in
            s.contrast = 26
            s.highlights = -35
            s.shadows = 10
            s.whites = 20
            s.blacks = -16
            s.clarity = 14
            s.vibrance = 24
            s.setPoints(curve((0, 0), (0.22, 0.17), (0.78, 0.83), (1, 1)), for: .rgb)
            s[.hsl(.hue, .red)] = -10
            s[.hsl(.saturation, .red)] = 15
            s[.hsl(.hue, .aqua)] = 15
            s[.hsl(.saturation, .aqua)] = 25
            s[.hsl(.hue, .blue)] = -16
            s[.hsl(.saturation, .blue)] = 24
            s[.hsl(.saturation, .purple)] = 25
            s[.hsl(.saturation, .magenta)] = 28
            s[.hsl(.luminance, .magenta)] = 10
            grade(&s, .shadows, hue: 215, saturation: 30, luminance: -10)
            grade(&s, .midtones, hue: 285, saturation: 10)
            grade(&s, .highlights, hue: 315, saturation: 18, luminance: 8)
        },
        // Monochromatic golden-amber cinema (Roger Deakins / Dune): bronze shadows,ochre midtones
        // and atmospheric warmth with muted blues.
        look("Cinematic", 5, "Warm Drama") { s in
            s.contrast = 30
            s.highlights = -25
            s.shadows = -12
            s.whites = 8
            s.blacks = -14
            s.clarity = 16
            s.saturation = -12
            s.setPoints(curve((0, 0.01), (0.22, 0.17), (0.78, 0.82), (1, 0.98)), for: .rgb)
            s.setPoints(curve((0, 0), (0.5, 0.53), (1, 1)), for: .red)
            s.setPoints(curve((0, 0.01), (0.5, 0.45), (1, 0.90)), for: .blue)
            s[.hsl(.saturation, .orange)] = 15
            s[.hsl(.hue, .yellow)] = -12
            s[.hsl(.saturation, .green)] = -35
            s[.hsl(.saturation, .blue)] = -40
            grade(&s, .global, hue: 36, saturation: 14)
            grade(&s, .shadows, hue: 26, saturation: 22, luminance: -10)
            grade(&s, .midtones, hue: 38, saturation: 16)
            grade(&s, .highlights, hue: 44, saturation: 20)
            s.vignette = -24
        },
    ]

    /// Distinct retro eras, alternative chemical processes and editorial matte prints.
    private static let vintagePack: [DevelopPreset] = [
        // Editorial matte print: lifted velvet shadow toe with S-curve midtone snap so the photo
        // looks printed on cotton rag rather than hazy.
        look("Vintage & Matte", 1, "Faded Matte") { s in
            s.contrast = 15
            s.highlights = -20
            s.shadows = 12
            s.saturation = -14
            s.vibrance = 10
            s.setPoints(curve((0, 0.11), (0.22, 0.21), (0.55, 0.54), (0.82, 0.84), (1, 0.95)), for: .rgb)
            s.setPoints(curve((0, 0.12), (0.5, 0.49), (1, 0.93)), for: .blue)
            s[.hsl(.saturation, .green)] = -20
            grade(&s, .shadows, hue: 205, saturation: 12, luminance: 6)
            grade(&s, .midtones, hue: 38, saturation: 8)
            grade(&s, .highlights, hue: 44, saturation: 12)
            s.grain = 14
        },
        // 1970s warm editorial print: ochre-mustard yellows, avocado greens, terracotta reds
        // and warm faded paper blacks.
        look("Vintage & Matte", 2, "Seventies") { s in
            s.contrast = 10
            s.highlights = -20
            s.shadows = 15
            s.setPoints(curve((0, 0.08), (0.25, 0.24), (0.75, 0.80), (1, 0.94)), for: .rgb)
            s.setPoints(curve((0, 0.04), (0.5, 0.54), (1, 0.98)), for: .red)
            s.setPoints(curve((0, 0.05), (0.5, 0.44), (1, 0.86)), for: .blue)
            s[.hsl(.hue, .red)] = 8
            s[.hsl(.saturation, .red)] = 15
            s[.hsl(.saturation, .orange)] = 20
            s[.hsl(.hue, .yellow)] = -15
            s[.hsl(.saturation, .yellow)] = 15
            s[.hsl(.hue, .green)] = -25
            s[.hsl(.saturation, .green)] = -15
            s[.hsl(.saturation, .blue)] = -28
            grade(&s, .global, hue: 46, saturation: 18)
            grade(&s, .shadows, hue: 75, saturation: 14)
            grade(&s, .highlights, hue: 42, saturation: 20)
            s.grain = 26
            s.vignette = -16
        },
        // Early color negative (Agfacolor / 1950s hand-tinted postcard): soft turquoise skies,
        // coral-peach reds and gentle nostalgia.
        look("Vintage & Matte", 6, "Midcentury Postcard") { s in
            s.contrast = 14
            s.highlights = -22
            s.shadows = 20
            s.whites = 8
            s.clarity = -6
            s.vibrance = 15
            s.saturation = -10
            s.setPoints(curve((0, 0.06), (0.25, 0.25), (0.75, 0.80), (1, 0.96)), for: .rgb)
            s.setPoints(curve((0, 0.03), (0.5, 0.54), (1, 0.99)), for: .red)
            s[.hsl(.hue, .red)] = 12
            s[.hsl(.saturation, .red)] = 18
            s[.hsl(.hue, .orange)] = 6
            s[.hsl(.saturation, .orange)] = 14
            s[.hsl(.luminance, .orange)] = 8
            s[.hsl(.hue, .yellow)] = -18
            s[.hsl(.hue, .green)] = 25
            s[.hsl(.saturation, .green)] = -20
            s[.hsl(.hue, .aqua)] = 12
            s[.hsl(.saturation, .aqua)] = 22
            s[.hsl(.hue, .blue)] = -26
            s[.hsl(.saturation, .blue)] = 12
            s[.hsl(.luminance, .blue)] = 6
            grade(&s, .shadows, hue: 190, saturation: 14, luminance: 4)
            grade(&s, .midtones, hue: 36, saturation: 10)
            grade(&s, .highlights, hue: 46, saturation: 22)
            s.grain = 18
        },
        // Slide film processed in C-41 chemicals (E-6 in C-41): high-contrast skewed channel
        // curves, emerald-cyan shadows and acid-yellow highlights.
        look("Vintage & Matte", 4, "Cross Process") { s in
            s.contrast = 32
            s.highlights = -12
            s.blacks = -12
            s.vibrance = 18
            s.saturation = 12
            s.setPoints(curve((0, 0.02), (0.25, 0.20), (0.75, 0.83), (1, 0.99)), for: .rgb)
            s.setPoints(curve((0, 0), (0.3, 0.22), (0.7, 0.82), (1, 1)), for: .red)
            s.setPoints(curve((0, 0.04), (0.5, 0.54), (1, 0.98)), for: .green)
            s.setPoints(curve((0, 0.10), (0.5, 0.45), (1, 0.88)), for: .blue)
            s[.hsl(.saturation, .red)] = 20
            s[.hsl(.hue, .yellow)] = 10
            s[.hsl(.saturation, .green)] = 15
            s[.hsl(.hue, .blue)] = -15
            s[.hsl(.saturation, .blue)] = -12
            grade(&s, .shadows, hue: 145, saturation: 28, luminance: -4)
            grade(&s, .midtones, hue: 110, saturation: 10)
            grade(&s, .highlights, hue: 56, saturation: 30)
            s.grain = 16
        },
        // Sun-bleached coastal print: lifted rose-gold highlights, seafoam-teal shadows and soft
        // pastel midtones.
        look("Vintage & Matte", 5, "Dusty Pastel") { s in
            s.contrast = 6
            s.highlights = -18
            s.shadows = 28
            s.whites = 14
            s.vibrance = 16
            s.saturation = -18
            s[.curveLights] = 12
            s.setPoints(curve((0, 0.08), (0.28, 0.29), (0.70, 0.75), (1, 0.97)), for: .rgb)
            s.setPoints(curve((0, 0.05), (0.5, 0.53), (1, 0.99)), for: .red)
            s.setPoints(curve((0, 0.09), (0.5, 0.49), (1, 0.95)), for: .blue)
            s[.hsl(.hue, .red)] = 8
            s[.hsl(.luminance, .orange)] = 12
            s[.hsl(.hue, .green)] = 20
            s[.hsl(.saturation, .green)] = -25
            s[.hsl(.luminance, .green)] = 10
            s[.hsl(.hue, .blue)] = -16
            s[.hsl(.luminance, .blue)] = 8
            grade(&s, .shadows, hue: 192, saturation: 14, luminance: 6)
            grade(&s, .midtones, hue: 345, saturation: 8, luminance: 4)
            grade(&s, .highlights, hue: 335, saturation: 16, luminance: 6)
        },
    ]
}
