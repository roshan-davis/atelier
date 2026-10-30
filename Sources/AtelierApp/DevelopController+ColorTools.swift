import AtelierCore
import Foundation

/// A tone curve saved from the Tone Curve's menu, or one of Lightroom's built-in curves.
struct SavedCurve: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var points: [DevelopSettings.CurvePoint]

    private static let key = "develop.savedCurves"

    /// Lightroom's point curve presets.
    static let builtIn: [SavedCurve] = [
        SavedCurve(name: "Linear", points: DevelopSettings.CurvePoint.identity),
        SavedCurve(name: "Medium Contrast", points: scaled([(0, 0), (32, 22), (64, 56), (128, 128), (192, 196), (255, 255)])),
        SavedCurve(name: "Strong Contrast", points: scaled([(0, 0), (32, 16), (64, 50), (128, 128), (192, 202), (255, 255)])),
    ]

    private static func scaled(_ points: [(Double, Double)]) -> [DevelopSettings.CurvePoint] {
        points.map { DevelopSettings.CurvePoint(x: $0.0 / 255, y: $0.1 / 255) }
    }

    static func load() -> [SavedCurve] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedCurve].self, from: data)) ?? []
    }

    static func save(_ curves: [SavedCurve]) {
        guard let data = try? JSONEncoder().encode(curves) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// The Targeted Adjustment Tool, Point Color and the Tone Curve's menu.
extension DevelopController {
    /// A Targeted Adjustment drag: the sliders it moves, each with its value at the press and its
    /// share of the drag, or the point curve point it moves. Filled in once the clicked color has
    /// been measured; a drag that moves before then catches up.
    struct TargetDrag {
        var values: [DevelopSettings.Parameter: Double] = [:]
        var weights: [DevelopSettings.Parameter: Double] = [:]
        var curvePoint: (channel: DevelopSettings.CurveChannel, index: Int, points: [DevelopSettings.CurvePoint])?
        var step = ""
        var ready = false
        var distance = 0.0
    }

    /// Slider units per point dragged, as in Lightroom (a long drag spans the range).
    private static let targetSpeed = 0.5

    /// The Tone Curve panel's view ("parametric" or "point") and channel, which the Targeted
    /// Adjustment Tool follows.
    static let curveModeKey = "develop.curveMode"
    static let curveChannelKey = "develop.curveChannel"

    func targetedDrag(_ drag: PhotoDrag) {
        guard let picker, picker.isTargeted else { return }
        switch drag {
        case .began(let point):
            beginTarget(picker, at: point)
        case .moved(let distance):
            targetDrag?.distance = distance
            applyTarget()
        case .ended:
            targetDrag = nil
        }
    }

    private func beginTarget(_ picker: PhotoPicker, at point: CGPoint) {
        targetDrag = TargetDrag()
        pickerMessage = nil
        var sampled = settings
        switch picker {
        case .targetCurve: sampled.setPanel(.toneCurve, on: false)
        case .targetColor: sampled.setPanel(.hsl, on: false)
        default:
            // The B&W Mix weighs the colors before the photo turns gray.
            sampled.monochrome = false
            sampled.setPanel(.hsl, on: false)
        }
        let current = settings
        let channel = targetChannel
        sampleColor(at: point, settings: sampled) { [weak self] sample in
            guard let self, self.targetDrag != nil, self.picker == picker else { return }
            guard let sample else {
                self.targetDrag = nil
                self.pickerMessage = "Cannot read the color there. Try another spot."
                return
            }
            var drag = self.targetDrag ?? TargetDrag()
            switch picker {
            case .targetCurve:
                let tone = TargetedAdjustment.tone(of: sample)
                if UserDefaults.standard.string(forKey: Self.curveModeKey) == "point" {
                    let curveChannel = DevelopSettings.CurveChannel(
                        rawValue: UserDefaults.standard.string(forKey: Self.curveChannelKey) ?? "rgb") ?? .rgb
                    let x: Double
                    switch curveChannel {
                    case .rgb: x = tone
                    case .red: x = sample.x
                    case .green: x = sample.y
                    case .blue: x = sample.z
                    }
                    var points = current.points(for: curveChannel)
                    let index: Int
                    if let near = points.firstIndex(where: { abs($0.x - x) < 0.03 }) {
                        index = near
                    } else {
                        points.append(DevelopSettings.CurvePoint(x: x, y: DevelopRenderer.pointCurveValue(points, at: x)))
                        points.sort { $0.x < $1.x }
                        index = points.firstIndex { $0.x == min(1, max(0, x)) } ?? 0
                    }
                    drag.curvePoint = (curveChannel, index, points)
                } else {
                    let weights = TargetedAdjustment.regionWeights(tone: tone, settings: current)
                    for (parameter, weight) in zip(DevelopRenderer.curveRegions, weights) where weight > 0.05 {
                        drag.weights[parameter] = weight
                    }
                    drag.step = "Targeted Tone Curve"
                }
            default:
                guard let bands = TargetedAdjustment.bandWeights(of: sample) else {
                    self.targetDrag = nil
                    self.pickerMessage = "That spot is gray, so no color slider moves it. Try a colored spot."
                    return
                }
                for (band, weight) in zip(DevelopSettings.ColorBand.allCases, bands) where weight > 0.05 {
                    let parameter: DevelopSettings.Parameter = picker == .targetGray ? .gray(band) : .hsl(channel, band)
                    drag.weights[parameter] = weight
                }
                drag.step = picker == .targetGray ? "Targeted B&W Mix" : "Targeted \(channel.rawValue)"
            }
            for parameter in drag.weights.keys { drag.values[parameter] = current[parameter] }
            drag.ready = true
            self.targetDrag = drag
            self.applyTarget()
        }
    }

    private func applyTarget() {
        guard let drag = targetDrag, drag.ready, drag.distance != 0 else { return }
        if let curvePoint = drag.curvePoint {
            let (channel, index, points) = curvePoint
            var moved = points
            guard moved.indices.contains(index) else { return }
            let start = moved[index]
            moved[index] = DevelopSettings.CurvePoint(x: start.x, y: start.y + drag.distance / 300)
            setPoints(moved, for: channel)
            return
        }
        var values: [DevelopSettings.Parameter: Double] = [:]
        for (parameter, weight) in drag.weights {
            let start = drag.values[parameter] ?? parameter.defaultValue
            let value = start + drag.distance * Self.targetSpeed * weight
            values[parameter] = min(parameter.range.upperBound, max(parameter.range.lowerBound, value.rounded()))
        }
        setValues(values, step: drag.step)
    }

    // MARK: Point Color

    /// The swatches that have a picked color.
    var pointColorSwatches: [Int] {
        (0..<DevelopSettings.pointColorCount).filter { settings.hasPointColor($0) }
    }

    /// Point Color's eyedropper: a click picks the color for the shown swatch if it is empty, or
    /// else for a new swatch (the last one is replaced when all four are in use).
    func pickPointColor(at point: CGPoint) {
        var sampled = settings
        // The colors as they reach Point Color: after HSL, before any swatch and the grading.
        for swatch in 0..<DevelopSettings.pointColorCount {
            for setting in DevelopSettings.PointColorSetting.allCases where !setting.isTarget {
                sampled[.pointColor(swatch, setting)] = DevelopSettings.Parameter.pointColor(swatch, setting).defaultValue
            }
        }
        sampled.setPanel(.colorGrading, on: false)
        sampleColor(at: point, settings: sampled) { [weak self] sample in
            guard let self, self.picker == .pointColor else { return }
            guard let sample, let target = TargetedAdjustment.pointColor(of: sample) else {
                self.pickerMessage = "That spot is gray, so it has no color to pick. Click a colored spot."
                return
            }
            let swatch = self.settings.hasPointColor(self.pointColorSwatch)
                ? (0..<DevelopSettings.pointColorCount).first { !self.settings.hasPointColor($0) }
                    ?? DevelopSettings.pointColorCount - 1
                : self.pointColorSwatch
            self.picker = nil
            self.pointColorSwatch = swatch
            self.setValues([.pointColor(swatch, .hue): target.hue, .pointColor(swatch, .chroma): target.chroma,
                            .pointColor(swatch, .lightness): target.lightness],
                           step: "Point Color \(swatch + 1)")
        }
    }

    /// Removes a swatch and everything it changes.
    func deletePointColor(_ swatch: Int) {
        var values: [DevelopSettings.Parameter: Double] = [:]
        for setting in DevelopSettings.PointColorSetting.allCases {
            values[.pointColor(swatch, setting)] = DevelopSettings.Parameter.pointColor(swatch, setting).defaultValue
        }
        setValues(values, step: "Delete Point Color \(swatch + 1)")
        if visualizesPointRange, pointColorSwatches.isEmpty { visualizesPointRange = false }
        DeleteFeedback.play(.remove)
    }

    // MARK: Tone Curve

    /// Arrow keys over the point curve: up and down move the hovered graph's selected point's
    /// output, left and right its input, by one level of 255 (ten with Shift).
    func nudgeCurvePoint(dx: Double, dy: Double, large: Bool) {
        guard let hovered = hoveredCurvePoint else { return }
        let (channel, index) = hovered
        var points = settings.points(for: channel)
        guard points.indices.contains(index) else { return }
        let step = (large ? 10.0 : 1.0) / 255
        let low = index == 0 ? 0 : points[index - 1].x + 0.01
        let high = index == points.count - 1 ? 1 : points[index + 1].x - 0.01
        let point = points[index]
        points[index] = DevelopSettings.CurvePoint(x: min(max(point.x + dx * step, low), high), y: point.y + dy * step)
        setPoints(points, for: channel)
    }

    func copyCurve(_ channel: DevelopSettings.CurveChannel) {
        copiedCurve = settings.points(for: channel)
    }

    func pasteCurve(onto channel: DevelopSettings.CurveChannel) {
        guard let copiedCurve else { return }
        setPoints(copiedCurve, for: channel)
    }

    func resetAllCurves() {
        let before = settings
        for channel in DevelopSettings.CurveChannel.allCases where before.points(for: channel) != DevelopSettings.CurvePoint.identity {
            setPoints([], for: channel)
        }
    }

    func saveCurve(named name: String, channel: DevelopSettings.CurveChannel) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        savedCurves.removeAll { $0.name == trimmed }
        savedCurves.append(SavedCurve(name: trimmed, points: settings.points(for: channel)))
        savedCurves.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func deleteSavedCurve(_ curve: SavedCurve) {
        savedCurves.removeAll { $0.id == curve.id }
        DeleteFeedback.play(.remove)
    }
}
