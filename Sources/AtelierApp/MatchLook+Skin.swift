import AppKit
import AtelierCore

/// Show Skin in the Match Look dialog: the face and body skin Select People finds, tinted red over
/// the photo and the reference, so a poor selection is visible before Apply.
extension MatchLookModel {
    /// Whether the tint shows: Show Skin is on and a skin treatment is chosen.
    var showsSkin: Bool { showSkin && skinMode != .off }

    func findSkinOverlays() {
        let session = previewSession
        let settings = base
        let reference = referenceCG
        let study = builtInReference
        let needsPhoto = photoSkinOverlay == nil
        let needsReference = referenceSkinOverlay == nil && reference != nil
        guard needsPhoto || needsReference else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let photo = needsPhoto ? session?.peopleMask(settings, selection: LookSkin.matchSelection).flatMap { Self.tinted($0) } : nil
            var referenceOverlay: CGImage?
            if needsReference, let reference {
                if let study {
                    // A study's skin is drawn, so Show Skin tints exactly the shapes marked skin.
                    referenceOverlay = study.skinMask(width: reference.width).flatMap { Self.tinted($0) }
                } else if let found = PeopleSkin.find(in: reference),
                          let mask = found.mask(LookSkin.matchSelection) {
                    referenceOverlay = Self.tinted(mask)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let photo { self.photoSkinOverlay = Self.image(photo) }
                    // A reference picked meanwhile gets its own search.
                    if let referenceOverlay, self.referenceCG === reference {
                        self.referenceSkinOverlay = Self.image(referenceOverlay)
                    }
                }
            }
        }
    }

    private static func image(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Red where the gray mask is white, clear elsewhere, as Masking's overlay tints.
    nonisolated static func tinted(_ mask: CGImage) -> CGImage? {
        let width = mask.width, height = mask.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: rect, mask: mask)
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.15, blue: 0.1, alpha: 0.55))
        context.fill(rect)
        return context.makeImage()
    }
}
