import AppKit
import AtelierCore
import Foundation

/// The Remove tool's spots (AT-066): adding them (Heal and Clone with a source picked next to
/// them; Content-Aware keeps one too, for Heal while its fill is found and for switching
/// modes), moving and changing them, and deleting them. Each change is one history step.
extension DevelopController {
    typealias Spot = DevelopSettings.Spot

    var spots: [Spot] { settings.spots }

    var selectedSpot: Spot? { settings.spots.first { $0.id == selectedSpotID } }

    /// The decoded photo's size (upright, uncropped) used for spot geometry.
    private var spotPhotoSize: CGSize { sourceSize ?? CGSize(width: 3, height: 2) }

    /// Adds a spot along `points` (one point for a click) with the panel's brush,
    /// its source picked where the photo looks most like the spot's surroundings.
    func addSpot(points: [DevelopSettings.MaskPoint]) {
        guard assetID != nil, !points.isEmpty else { return }
        var spot = Spot(mode: spotMode, points: points, size: spotSize, feather: spotFeather, opacity: spotOpacity)
        let ranked = SpotSource.ranked(for: spot, photo: spotPhotoSize, brightness: spotBrightnessReader())
        spot.offset = ranked.first ?? fallbackOffset(for: spot)
        var spots = settings.spots
        spots.append(spot)
        selectedSpotID = spot.id
        setSpots(spots, step: "Add \(spot.mode.title) Spot")
    }

    /// Lightroom's / key: the selected spot takes the next best source, or for Content-Aware,
    /// another fill.
    func newSourceForSelectedSpot() {
        guard let spot = selectedSpot else { return }
        if spot.mode == .contentAware {
            updateSpot(spot.id, step: "New Fill") { $0.variation += 1 }
            return
        }
        let ranked = SpotSource.ranked(for: spot, photo: spotPhotoSize, brightness: spotBrightnessReader())
        guard let offset = SpotSource.next(after: spot.offset, in: ranked, photo: spotPhotoSize) else { return }
        updateSpot(spot.id, step: "New Spot Source") { $0.offset = offset }
    }

    /// Moves a spot's source so it sits `offset` from the spot (dragging the source outline).
    func moveSpotSource(_ id: UUID, to offset: DevelopSettings.MaskPoint) {
        updateSpot(id, step: "Move Spot Source") { $0.offset = offset }
    }

    /// Moves a spot (and its source with it) to `points` (dragging the spot outline).
    func moveSpot(_ id: UUID, to points: [DevelopSettings.MaskPoint]) {
        updateSpot(id, step: "Move Spot") { $0.points = points }
    }

    /// The panel's Heal/Clone switch and sliders change the selected spot, as in Lightroom, and
    /// the brush for the next one.
    func setSpotMode(_ mode: Spot.Mode) {
        spotMode = mode
        if let id = selectedSpotID { updateSpot(id, step: "Spot: \(mode.title)") { $0.mode = mode } }
    }

    func setSpotSize(_ size: Double) {
        spotSize = min(max(size, Spot.sizeRange.lowerBound), Spot.sizeRange.upperBound)
        if let id = selectedSpotID { updateSpot(id, step: "Spot Size") { $0.size = self.spotSize } }
    }

    func setSpotFeather(_ feather: Double) {
        spotFeather = min(max(feather, 0), 100)
        if let id = selectedSpotID { updateSpot(id, step: "Spot Feather") { $0.feather = self.spotFeather } }
    }

    func setSpotOpacity(_ opacity: Double) {
        spotOpacity = min(max(opacity, 0), 100)
        if let id = selectedSpotID { updateSpot(id, step: "Spot Opacity") { $0.opacity = self.spotOpacity } }
    }

    /// Selects a spot (or none) and shows its settings on the panel's sliders.
    func selectSpot(_ id: UUID?) {
        selectedSpotID = id
        guard let spot = selectedSpot else { return }
        spotMode = spot.mode
        spotSize = spot.size
        spotFeather = spot.feather
        spotOpacity = spot.opacity
    }

    func deleteSelectedSpot() {
        guard let id = selectedSpotID, settings.spots.contains(where: { $0.id == id }) else { return }
        selectedSpotID = nil
        setSpots(settings.spots.filter { $0.id != id }, step: "Delete Spot")
        DeleteFeedback.play(.remove)
    }

    /// Clears every spot of the open photo (the panel's Reset and Clear All Spots).
    func deleteAllSpots() {
        guard !settings.spots.isEmpty else { return }
        selectedSpotID = nil
        setSpots([], step: "Clear All Spots")
        DeleteFeedback.play(.remove)
    }

    private func updateSpot(_ id: UUID, step: String, _ change: (inout Spot) -> Void) {
        guard let index = settings.spots.firstIndex(where: { $0.id == id }) else { return }
        var spots = settings.spots
        change(&spots[index])
        setSpots(spots, step: step)
    }

    /// Straight up from the spot, a little more than its size away, when no candidate fits
    /// (a spot as large as the photo).
    private func fallbackOffset(for spot: Spot) -> DevelopSettings.MaskPoint {
        let size = spotPhotoSize
        let distance = spot.size * Double(max(size.width, size.height)) * 1.25
        let up = spot.center.y - distance / Double(size.height) >= 0
        return DevelopSettings.MaskPoint(x: 0, y: (up ? -distance : distance) / Double(size.height))
    }

    /// Reads the photo's brightness for `SpotSource.ranked` from the proxy on screen (a small
    /// gray copy, made once per rendered image). Points outside the crop read as nil.
    private func spotBrightnessReader() -> ((DevelopSettings.MaskPoint) -> Double?)? {
        guard let image, let sourceSize, sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let id = ObjectIdentifier(image)
        if spotBrightness?.image != id {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let map = BrightnessMap(cgImage) else { return nil }
            spotBrightness = (id, map)
        }
        guard let map = spotBrightness?.map else { return nil }
        let crop = self.crop
        let output = crop.outputSize(sourceSize)
        guard output.width > 0, output.height > 0 else { return nil }
        return { point in
            let source = CGPoint(x: CGFloat(point.x) * sourceSize.width, y: CGFloat(point.y) * sourceSize.height)
            let shown = crop.outputPoint(fromSource: source, sourceSize: sourceSize)
            return map.value(x: Double(shown.x / output.width), y: Double(shown.y / output.height))
        }
    }
}
