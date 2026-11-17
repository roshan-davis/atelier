import Foundation

/// Presets for a single Develop panel, picked from a Preset menu at the top of that panel
/// (Rosh, Nov 12, 2026): Tone Curve presets set the whole curve (Parametric regions and splits,
/// the RGB, Red, Green and Blue point curves and Refine Saturation); Color Grading presets set
/// every wheel, Blending and Balance. Nothing else on the photo changes.
///
/// A section preset is an ordinary `DevelopPreset` whose only part is the panel's, so it applies,
/// blends and stores exactly as a Develop preset that includes only that panel would; it is just
/// listed in the panel instead of the Presets panel. Lightroom Classic keeps saved point curves
/// the same way, apart from its Develop presets. The user's section presets are kept in their own
/// file per panel, beside Presets.json.
public enum SectionPresetKind: String, CaseIterable, Sendable {
    case toneCurve, colorGrading

    public var part: DevelopPreset.Part {
        switch self {
        case .toneCurve: return .toneCurve
        case .colorGrading: return .colorGrading
        }
    }

    public var panel: DevelopSettings.Panel {
        switch self {
        case .toneCurve: return .toneCurve
        case .colorGrading: return .colorGrading
        }
    }

    /// "Tone Curve", "Color Grading".
    public var title: String { panel.title }

    /// The built-in preset that clears the panel, listed first.
    public var neutralName: String {
        switch self {
        case .toneCurve: return "Linear"
        case .colorGrading: return "None"
        }
    }

    /// Where the user's presets for this panel are kept.
    public func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("\(title) Presets.json")
    }

    public static var defaultFolder: URL { PresetStore.defaultURL.deletingLastPathComponent() }

    /// Built-in groups in menu order.
    public var builtInGroups: [String] {
        switch self {
        case .toneCurve: return ToneCurvePresets.groups
        case .colorGrading: return ColorGradingPresets.groups
        }
    }

    public var builtIn: [DevelopPreset] {
        switch self {
        case .toneCurve: return ToneCurvePresets.all
        case .colorGrading: return ColorGradingPresets.all
        }
    }

    /// A user preset of this panel from the photo's current settings: only the panel's own
    /// settings are kept, and the panel is saved on (applying a preset is an edit, and an edit
    /// turns its panel on).
    public func preset(named name: String, from settings: DevelopSettings, id: UUID = UUID()) -> DevelopPreset {
        var stored = DevelopPreset(name: name, parts: [part], settings: settings).applied(to: .neutral)
        stored.setPanel(panel, on: true)
        return DevelopPreset(id: id, name: name, group: DevelopPreset.defaultGroup, parts: [part], settings: stored)
    }

    /// Whether the photo's panel matches `preset` exactly. The panel's switch is ignored, so a
    /// look turned off to compare still shows its name.
    public func matches(_ preset: DevelopPreset, _ settings: DevelopSettings) -> Bool {
        var applied = preset.applied(to: settings)
        applied.setPanel(panel, on: settings.isOn(panel))
        return applied == settings
    }

    /// The first preset in `presets` that the panel matches, or nil for a custom setting.
    public func matching(_ settings: DevelopSettings, in presets: [DevelopPreset]) -> DevelopPreset? {
        presets.first { matches($0, settings) }
    }

    /// The point-curve channels `preset` bends, RGB first, so the Tone Curve panel can show them.
    public static func bentChannels(of preset: DevelopPreset) -> [DevelopSettings.CurveChannel] {
        DevelopSettings.CurveChannel.allCases.filter {
            preset.settings.points(for: $0) != DevelopSettings.CurvePoint.identity
        }
    }

    /// Fixed IDs for the built-ins: panel number, group number (its place in `builtInGroups`,
    /// so new groups go at the end) and the look's index in its group. Never reuse an index for
    /// another look.
    fileprivate var number: Int {
        switch self {
        case .toneCurve: return 1
        case .colorGrading: return 2
        }
    }

    fileprivate func look(_ group: String, _ index: Int, _ name: String,
                          _ configure: (inout DevelopSettings) -> Void) -> DevelopPreset {
        var settings = DevelopSettings()
        configure(&settings)
        let groupNumber = builtInGroups.firstIndex(of: group)!
        let n = number * 0x100 + groupNumber * 0x10 + index
        let id = UUID(uuidString: String(format: "5EC7A0B5-%04lX-4C5E-9A7E-0A7E11E5%04lX", n, n))!
        return DevelopPreset(id: id, name: name, group: group, parts: [part], settings: settings, isBuiltIn: true)
    }
}

/// A store of the user's presets for one panel (same file format as Presets.json).
extension PresetStore {
    public convenience init(section: SectionPresetKind, folder: URL = SectionPresetKind.defaultFolder) {
        self.init(fileURL: section.fileURL(in: folder))
    }
}

// MARK: Tone Curve

/// Built-in Tone Curve presets: characterful looks made only from the curve, in the spirit of
/// Easel's and Photoshop's Curves presets (Rosh, Nov 13, 2026: the first set was too tame).
/// Film processes and cinematic looks use the Red, Green and Blue curves; Basic holds
/// Lightroom's own Medium and Strong Contrast points. Tuned on the preset fixtures with
/// Scripts/presets/develop_sim.py.
enum ToneCurvePresets {
    static let groups = ["Basic", "Film Process", "Cinematic", "Fade", "Effects"]

    private static let kind = SectionPresetKind.toneCurve

    /// Points given in Lightroom's 0 to 255 units.
    private static func curve(_ points: (Double, Double)...) -> [DevelopSettings.CurvePoint] {
        points.map { DevelopSettings.CurvePoint(x: $0.0 / 255, y: $0.1 / 255) }
    }

    static let all: [DevelopPreset] = [
        kind.look("Basic", 0, "Linear") { _ in },
        // Lightroom's own Medium Contrast and Strong Contrast points.
        kind.look("Basic", 1, "Medium Contrast") { s in
            s.setPoints(curve((0, 0), (32, 22), (64, 56), (128, 128), (192, 196), (255, 255)), for: .rgb)
        },
        kind.look("Basic", 2, "Strong Contrast") { s in
            s.setPoints(curve((0, 0), (32, 16), (64, 50), (128, 128), (192, 202), (255, 255)), for: .rgb)
        },
        kind.look("Basic", 3, "Lighter") { s in
            s.setPoints(curve((0, 0), (128, 155), (255, 255)), for: .rgb)
        },
        kind.look("Basic", 4, "Darker") { s in
            s.setPoints(curve((0, 0), (128, 100), (255, 255)), for: .rgb)
        },
        // Slide film developed as negative (E-6 in C-41): punchy red and green, blue lifted in
        // the shadows and held down in the highlights, so yellow highlights and cyan shadows.
        kind.look("Film Process", 0, "Cross Process") { s in
            s.setPoints(curve((0, 0), (64, 40), (192, 222), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (64, 48), (192, 214), (255, 255)), for: .green)
            s.setPoints(curve((0, 40), (128, 120), (255, 200)), for: .blue)
        },
        // Negative film developed as slide (C-41 in E-6): flat, pale and cyan-green.
        kind.look("Film Process", 1, "Reverse Cross Process") { s in
            s.setPoints(curve((0, 30), (128, 140), (255, 240)), for: .rgb)
            s.setPoints(curve((0, 0), (128, 118), (255, 235)), for: .red)
            s.setPoints(curve((0, 10), (128, 138), (255, 255)), for: .green)
            s.setPoints(curve((0, 30), (128, 140), (255, 250)), for: .blue)
        },
        // Toy-camera look: deep contrast in red and green, inky blue-black shadows, warm highlights.
        kind.look("Film Process", 2, "Lomo") { s in
            s.setPoints(curve((0, 0), (64, 42), (192, 220), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (64, 44), (192, 218), (255, 255)), for: .green)
            s.setPoints(curve((0, 24), (64, 50), (192, 190), (255, 225)), for: .blue)
        },
        kind.look("Film Process", 3, "Expired Film") { s in
            s.setPoints(curve((0, 28), (128, 132), (255, 238)), for: .rgb)
            s.setPoints(curve((0, 10), (128, 135), (255, 250)), for: .red)
            s.setPoints(curve((0, 20), (128, 128), (255, 232)), for: .green)
            s.setPoints(curve((0, 30), (128, 118), (255, 215)), for: .blue)
        },
        kind.look("Film Process", 4, "Instant Film") { s in
            s.setPoints(curve((0, 36), (64, 78), (192, 200), (255, 238)), for: .rgb)
            s.setPoints(curve((0, 12), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (128, 120), (255, 226)), for: .blue)
        },
        // Warm skin and highlights against cool shadows, the way colorists did it with curves.
        kind.look("Cinematic", 0, "Teal & Orange") { s in
            s.setPoints(curve((0, 0), (64, 54), (192, 202), (255, 255)), for: .rgb)
            s.setPoints(curve((0, 0), (64, 52), (192, 212), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (64, 66), (192, 192), (255, 250)), for: .green)
            s.setPoints(curve((0, 0), (64, 82), (192, 172), (255, 232)), for: .blue)
        },
        kind.look("Cinematic", 1, "Matrix Green") { s in
            s.setPoints(curve((0, 0), (64, 52), (192, 200), (255, 255)), for: .rgb)
            s.setPoints(curve((0, 0), (128, 110), (255, 225)), for: .red)
            s.setPoints(curve((0, 10), (128, 140), (255, 255)), for: .green)
            s.setPoints(curve((0, 0), (128, 108), (255, 215)), for: .blue)
        },
        kind.look("Cinematic", 2, "Neon Night") { s in
            s.setPoints(curve((0, 0), (64, 46), (192, 215), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (64, 58), (192, 185), (255, 235)), for: .green)
            s.setPoints(curve((0, 30), (64, 84), (192, 205), (255, 255)), for: .blue)
        },
        // Daylight shot made to read as night: darker by about a stop and a half, blue.
        kind.look("Cinematic", 3, "Day for Night") { s in
            s.setPoints(curve((0, 0), (128, 62), (255, 160)), for: .rgb)
            s.setPoints(curve((0, 0), (128, 100), (255, 190)), for: .red)
            s.setPoints(curve((0, 0), (128, 118), (255, 215)), for: .green)
            s.setPoints(curve((0, 28), (128, 155), (255, 255)), for: .blue)
        },
        kind.look("Fade", 0, "Matte") { s in
            s.setPoints(curve((0, 26), (64, 66), (192, 196), (255, 250)), for: .rgb)
        },
        kind.look("Fade", 1, "Faded Film") { s in
            s.setPoints(curve((0, 36), (70, 76), (190, 192), (255, 236)), for: .rgb)
        },
        kind.look("Fade", 2, "Vintage Fade") { s in
            s.setPoints(curve((0, 40), (128, 135), (255, 232)), for: .rgb)
            s.setPoints(curve((0, 14), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (255, 210)), for: .blue)
        },
        // On the RGB curve, so the panel shows it as the falling line it is. The RGB curve
        // keeps each channel's place between the brightest and darkest, so a falling straight
        // line inverts every channel exactly, the same as inverting Red, Green and Blue.
        kind.look("Effects", 0, "Negative") { s in
            s.setPoints(curve((0, 255), (255, 0)), for: .rgb)
        },
        // A negative as if printed without the orange film base taken out.
        kind.look("Effects", 1, "Color Negative") { s in
            s.setPoints(curve((0, 255), (255, 30)), for: .red)
            s.setPoints(curve((0, 240), (255, 0)), for: .green)
            s.setPoints(curve((0, 200), (255, 0)), for: .blue)
        },
        // The Sabattier effect: tones rise to a peak, then the brightest turn back toward dark.
        kind.look("Effects", 2, "Solarize") { s in
            s.setPoints(curve((0, 0), (150, 230), (255, 40)), for: .rgb)
        },
    ]
}

// MARK: Color Grading

/// Built-in Color Grading presets, grouped by the color-harmony pattern their hues follow
/// (positions on the hue wheel: complementary = opposite, split complementary = one hue and the
/// two either side of its opposite, analogous = neighbors, triad = three evenly apart). Research
/// (Nov 12, 2026, reports/color-harmony-grading-2026-11-12.md) found these patterns are a design
/// tradition, not a law of perception, so they are named looks rather than rules. A wheel at
/// Saturation 100 adds only 0.10 Oklab chroma, so the looks use high saturation to read clearly
/// (Rosh, Nov 13, 2026: the first set, at 36 and under, was too tame). Warm hues sit in the
/// highlights or midtones so skin stays natural. Hues are Lightroom's (0 red, 30 orange,
/// 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta).
enum ColorGradingPresets {
    static let groups = ["Complementary", "Split Complementary", "Analogous", "Triad", "Monochrome Toning"]

    private static let kind = SectionPresetKind.colorGrading

    private static func grade(_ s: inout DevelopSettings, _ region: DevelopSettings.GradeRegion, _ hue: Double,
                              _ saturation: Double, luminance: Double = 0) {
        s[region.hue] = hue
        s[region.saturation] = saturation
        s[region.luminance] = luminance
    }

    static let all: [DevelopPreset] = [
        kind.look("Complementary", 0, "None") { _ in },
        // Teal shadows opposite orange highlights, which sit on skin's own hue.
        kind.look("Complementary", 1, "Teal & Orange") { s in
            grade(&s, .shadows, 195, 90)
            grade(&s, .highlights, 38, 75)
            s[.gradeBlending] = 60
        },
        kind.look("Complementary", 2, "Blockbuster") { s in
            grade(&s, .shadows, 205, 100, luminance: -10)
            grade(&s, .midtones, 30, 35)
            grade(&s, .highlights, 40, 60)
            s[.gradeBalance] = -15
        },
        kind.look("Complementary", 3, "Neon Noir") { s in
            grade(&s, .shadows, 190, 90, luminance: -5)
            grade(&s, .highlights, 320, 75)
        },
        kind.look("Complementary", 4, "Desert Heat") { s in
            grade(&s, .shadows, 200, 50)
            grade(&s, .midtones, 32, 60)
            grade(&s, .highlights, 42, 75)
        },
        // Teal shadows; its opposite (red) split into rose midtones and amber highlights.
        kind.look("Split Complementary", 0, "Coral Reef") { s in
            grade(&s, .shadows, 190, 80)
            grade(&s, .midtones, 340, 35)
            grade(&s, .highlights, 40, 60)
        },
        // Orange highlights; its opposite (blue) split into cyan midtones and deep blue shadows.
        kind.look("Split Complementary", 1, "Sunset Split") { s in
            grade(&s, .shadows, 246, 80)
            grade(&s, .midtones, 186, 30)
            grade(&s, .highlights, 36, 70)
        },
        kind.look("Analogous", 0, "Golden Hour") { s in
            grade(&s, .shadows, 20, 55)
            grade(&s, .midtones, 32, 50)
            grade(&s, .highlights, 48, 80)
            grade(&s, .global, 40, 15)
        },
        kind.look("Analogous", 1, "Moonlight") { s in
            grade(&s, .shadows, 235, 90, luminance: -15)
            grade(&s, .midtones, 215, 55)
            grade(&s, .highlights, 200, 30)
            grade(&s, .global, 220, 15)
        },
        kind.look("Analogous", 2, "Matrix Green") { s in
            grade(&s, .shadows, 140, 85)
            grade(&s, .midtones, 120, 60)
            grade(&s, .highlights, 90, 40)
        },
        kind.look("Analogous", 3, "Arctic") { s in
            grade(&s, .shadows, 210, 75)
            grade(&s, .midtones, 195, 45)
            grade(&s, .highlights, 185, 30)
        },
        kind.look("Analogous", 4, "Autumn") { s in
            grade(&s, .shadows, 10, 65)
            grade(&s, .midtones, 28, 60)
            grade(&s, .highlights, 45, 55)
        },
        // Three hues 120° apart, one per tonal range.
        kind.look("Triad", 0, "Psychedelic") { s in
            grade(&s, .shadows, 270, 85)
            grade(&s, .midtones, 150, 50)
            grade(&s, .highlights, 30, 75)
        },
        kind.look("Triad", 1, "Technicolor") { s in
            grade(&s, .shadows, 240, 70)
            grade(&s, .midtones, 120, 25)
            grade(&s, .highlights, 0, 55)
        },
        // One hue through every range: toning, mainly for Black & White.
        kind.look("Monochrome Toning", 0, "Sepia") { s in
            grade(&s, .shadows, 30, 85)
            grade(&s, .midtones, 36, 70)
            grade(&s, .highlights, 45, 45)
        },
        kind.look("Monochrome Toning", 1, "Cyanotype") { s in
            grade(&s, .shadows, 215, 100)
            grade(&s, .midtones, 210, 80)
            grade(&s, .highlights, 200, 40)
        },
        kind.look("Monochrome Toning", 2, "Selenium") { s in
            grade(&s, .shadows, 290, 55)
            grade(&s, .midtones, 330, 25)
        },
        kind.look("Monochrome Toning", 3, "Gold Tone") { s in
            grade(&s, .shadows, 35, 45)
            grade(&s, .midtones, 45, 60)
            grade(&s, .highlights, 50, 80)
        },
    ]
}
