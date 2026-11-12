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

/// Built-in Tone Curve presets. Contrast curves follow Lightroom's Linear, Medium Contrast and
/// Strong Contrast points; the rest are Atelier's own, made only from the curve so they combine
/// with any Basic or Color Grading setting. All keep black at 0 and white at 255 except the
/// Fade looks, whose point is to lift black and lower white.
enum ToneCurvePresets {
    static let groups = ["Contrast", "Brightness", "Fade", "Color"]

    private static let kind = SectionPresetKind.toneCurve

    /// Points given in Lightroom's 0 to 255 units.
    private static func curve(_ points: (Double, Double)...) -> [DevelopSettings.CurvePoint] {
        points.map { DevelopSettings.CurvePoint(x: $0.0 / 255, y: $0.1 / 255) }
    }

    static let all: [DevelopPreset] = [
        kind.look("Contrast", 0, "Linear") { _ in },
        kind.look("Contrast", 1, "Soft Contrast") { s in
            s.setPoints(curve((0, 0), (64, 60), (128, 128), (192, 196), (255, 255)), for: .rgb)
        },
        // Lightroom's own Medium Contrast and Strong Contrast points.
        kind.look("Contrast", 2, "Medium Contrast") { s in
            s.setPoints(curve((0, 0), (32, 22), (64, 56), (128, 128), (192, 196), (255, 255)), for: .rgb)
        },
        kind.look("Contrast", 3, "Strong Contrast") { s in
            s.setPoints(curve((0, 0), (32, 16), (64, 50), (128, 128), (192, 202), (255, 255)), for: .rgb)
        },
        // Parametric, so it stays editable with the region sliders.
        kind.look("Contrast", 4, "Punchy Midtones") { s in
            s[.curveLights] = 18
            s[.curveDarks] = -18
        },
        kind.look("Brightness", 0, "Lighter") { s in
            s.setPoints(curve((0, 0), (128, 150), (255, 255)), for: .rgb)
        },
        kind.look("Brightness", 1, "Darker") { s in
            s.setPoints(curve((0, 0), (128, 106), (255, 255)), for: .rgb)
        },
        kind.look("Brightness", 2, "Open Shadows") { s in
            s.setPoints(curve((0, 0), (40, 54), (110, 118), (255, 255)), for: .rgb)
        },
        kind.look("Brightness", 3, "Soft Highlights") { s in
            s.setPoints(curve((0, 0), (128, 130), (205, 198), (255, 242)), for: .rgb)
        },
        kind.look("Fade", 0, "Matte") { s in
            s.setPoints(curve((0, 26), (64, 66), (192, 196), (255, 250)), for: .rgb)
        },
        kind.look("Fade", 1, "Faded Film") { s in
            s.setPoints(curve((0, 36), (70, 76), (190, 192), (255, 236)), for: .rgb)
        },
        kind.look("Fade", 2, "Matte Contrast") { s in
            s.setPoints(curve((0, 30), (50, 40), (128, 128), (200, 210), (255, 248)), for: .rgb)
        },
        // Warm highlights and cool shadows with the channel curves: the complementary pair of
        // Color Grading's Teal & Orange, made the way colorists did it before grading wheels.
        kind.look("Color", 0, "Warm Highlights, Cool Shadows") { s in
            s.setPoints(curve((0, 0), (64, 58), (192, 200), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (64, 70), (192, 186), (255, 252)), for: .blue)
        },
        kind.look("Color", 1, "Cool Fade") { s in
            s.setPoints(curve((0, 18), (64, 68), (192, 194), (255, 248)), for: .rgb)
            s.setPoints(curve((0, 22), (255, 245)), for: .blue)
        },
        kind.look("Color", 2, "Warm Fade") { s in
            s.setPoints(curve((0, 18), (64, 68), (192, 194), (255, 248)), for: .rgb)
            s.setPoints(curve((0, 16), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (255, 232)), for: .blue)
        },
        // Film developed in the other process's chemicals: cyan-green shadows, yellow highlights.
        kind.look("Color", 3, "Cross Process") { s in
            s.setPoints(curve((0, 0), (64, 45), (192, 215), (255, 255)), for: .red)
            s.setPoints(curve((0, 0), (64, 50), (192, 210), (255, 255)), for: .green)
            s.setPoints(curve((0, 30), (255, 220)), for: .blue)
        },
    ]
}

// MARK: Color Grading

/// Built-in Color Grading presets, grouped by the color-harmony pattern their hues follow
/// (positions on the hue wheel: complementary = opposite, split complementary = one hue and the
/// two either side of its opposite, analogous = neighbors, triad = three evenly apart). Research
/// (Nov 12, 2026, reports/color-harmony-grading-2026-11-12.md) found these patterns are a design
/// tradition, not a law of perception; the presets are starting points with modest saturation,
/// and warm hues sit in the highlights or midtones so skin stays natural. Hues are Lightroom's
/// (0 red, 30 orange, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta).
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
        // The film look: teal shadows opposite orange highlights, which sit on skin's own hue.
        kind.look("Complementary", 1, "Teal & Orange") { s in
            grade(&s, .shadows, 194, 30)
            grade(&s, .highlights, 36, 24)
            s[.gradeBlending] = 60
        },
        kind.look("Complementary", 2, "Blue & Gold") { s in
            grade(&s, .shadows, 225, 24)
            grade(&s, .highlights, 48, 26)
        },
        // The reverse pair: warm shadows under cool, clean highlights (dusk, moonlight).
        kind.look("Complementary", 3, "Warm Shadows, Cool Highlights") { s in
            grade(&s, .shadows, 30, 20)
            grade(&s, .highlights, 205, 14)
        },
        kind.look("Complementary", 4, "Green & Magenta") { s in
            grade(&s, .shadows, 150, 18)
            grade(&s, .highlights, 320, 10)
        },
        // Orange highlights; the two neighbors of its opposite (blue) in shadows and midtones.
        kind.look("Split Complementary", 0, "Orange with Cyan & Blue") { s in
            grade(&s, .shadows, 240, 24)
            grade(&s, .midtones, 185, 8)
            grade(&s, .highlights, 36, 22)
        },
        kind.look("Split Complementary", 1, "Gold with Teal & Violet") { s in
            grade(&s, .shadows, 270, 18)
            grade(&s, .midtones, 200, 8)
            grade(&s, .highlights, 50, 22)
        },
        kind.look("Analogous", 0, "Golden Hour") { s in
            grade(&s, .shadows, 18, 18)
            grade(&s, .midtones, 32, 12)
            grade(&s, .highlights, 48, 24)
        },
        kind.look("Analogous", 1, "Blue Hour") { s in
            grade(&s, .shadows, 240, 26)
            grade(&s, .midtones, 215, 10)
            grade(&s, .highlights, 190, 12)
        },
        kind.look("Analogous", 2, "Forest") { s in
            grade(&s, .shadows, 160, 18)
            grade(&s, .midtones, 110, 8)
            grade(&s, .highlights, 70, 16)
        },
        kind.look("Analogous", 3, "Rose") { s in
            grade(&s, .shadows, 300, 14)
            grade(&s, .midtones, 340, 8)
            grade(&s, .highlights, 20, 16)
        },
        // Three hues 120° apart: kept low, since three strong tints fight each other.
        kind.look("Triad", 0, "Orange, Teal-Green & Violet") { s in
            grade(&s, .shadows, 270, 16)
            grade(&s, .midtones, 150, 6)
            grade(&s, .highlights, 30, 18)
        },
        kind.look("Triad", 1, "Red, Green & Blue") { s in
            grade(&s, .shadows, 240, 14)
            grade(&s, .midtones, 120, 5)
            grade(&s, .highlights, 0, 12)
        },
        // One hue through every range: toning, mainly for Black & White.
        kind.look("Monochrome Toning", 0, "Sepia") { s in
            grade(&s, .shadows, 30, 26)
            grade(&s, .midtones, 36, 18)
            grade(&s, .highlights, 45, 14)
        },
        kind.look("Monochrome Toning", 1, "Cyanotype") { s in
            grade(&s, .shadows, 215, 36)
            grade(&s, .midtones, 210, 22)
            grade(&s, .highlights, 200, 10)
        },
        kind.look("Monochrome Toning", 2, "Selenium") { s in
            grade(&s, .shadows, 290, 14)
            grade(&s, .midtones, 330, 6)
        },
    ]
}
