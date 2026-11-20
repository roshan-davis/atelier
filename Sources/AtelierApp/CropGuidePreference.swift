import AtelierCore
import Foundation

/// The crop tool's guide overlay, its orientation and when it shows. Kept for the person, not per
/// photo, as in Lightroom; the crop view and panel read the same keys with `@AppStorage`, so a
/// change from the menu, a key or an agent shows at once.
enum CropGuidePreference {
    static let guideKey = "crop.guide"
    static let orientationKey = "crop.guideOrientation"
    static let visibilityKey = "crop.guideVisibility"

    static var guide: CropGuide {
        get { UserDefaults.standard.string(forKey: guideKey).flatMap(CropGuide.init(rawValue:)) ?? .thirds }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: guideKey) }
    }

    static var orientation: Int {
        get { UserDefaults.standard.integer(forKey: orientationKey) }
        set { UserDefaults.standard.set(newValue, forKey: orientationKey) }
    }

    static var visibility: CropGuideVisibility {
        get { UserDefaults.standard.string(forKey: visibilityKey).flatMap(CropGuideVisibility.init(rawValue:)) ?? .always }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: visibilityKey) }
    }

    /// O in the crop tool.
    static func next() { guide = guide.next }

    /// ⇧O in the crop tool. Returns false when the guide looks the same every way round.
    @discardableResult
    static func turn() -> Bool {
        let count = guide.orientationCount
        guard count > 1 else { return false }
        orientation = (((orientation % count) + count) % count + 1) % count
        return true
    }
}
