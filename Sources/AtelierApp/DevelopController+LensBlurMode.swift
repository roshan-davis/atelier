import AtelierCore
import Foundation

/// The Lens Blur mode's state that isn't about rendering (AT-074): which Lens Blur photo the
/// open photo has and whether it still matches. Opening and closing the mode is
/// `isLensBlurring` (DevelopController.swift); Save is `LibraryModel.saveLensBlur()`.
extension DevelopController {
    /// What the Lens Blur panel says about the saved photo.
    enum LensBlurPhotoState: Equatable {
        /// No Lens Blur photo yet: Save makes one.
        case none
        /// The Lens Blur photo matches the photo's settings now.
        case current
        /// Something changed since the last Save (here or in Develop): Save updates it.
        case outOfDate
    }

    var lensBlurPhotoState: LensBlurPhotoState {
        guard let saved = lensBlurPhoto else { return .none }
        guard let madeFrom = saved.madeFrom else { return .outOfDate }
        return madeFrom == settings ? .current : .outOfDate
    }

    /// Reads which Lens Blur photo is stacked on the open photo.
    func loadLensBlurPhoto() {
        guard let assetID, let version = try? LensBlurPhoto.version(of: assetID, catalog: catalog),
              let id = version.derivedAssetId else {
            lensBlurPhoto = nil
            return
        }
        lensBlurPhoto = (id: id, madeFrom: LensBlurPhoto.madeFrom(version))
    }
}
