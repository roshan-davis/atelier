import CoreGraphics
import Foundation

/// What one image on the Develop photo view is: which open of which photo, which edit, which
/// part of the photo and how many pixels it has across that part.
public struct DisplayTag: Equatable, Sendable {
    /// The open it belongs to (`DevelopController.openGeneration`): a higher one is a newer photo.
    public var photo: Int
    /// The render it came from (`DevelopController.renderCount`): a higher one is a newer edit.
    /// −1 for a stand-in (the cached preview or thumbnail shown while the photo decodes).
    public var revision: Int
    /// The part of the photo it shows, 0...1 across and down from the top-left; the unit
    /// rectangle for the whole photo.
    public var region: CGRect
    /// Its width in pixels.
    public var pixelWidth: Double

    public static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    public init(photo: Int, revision: Int, region: CGRect = DisplayTag.whole, pixelWidth: Double) {
        self.photo = photo
        self.revision = revision
        self.region = region
        self.pixelWidth = pixelWidth
    }

    public var isWhole: Bool { region.width >= 0.999 && region.height >= 0.999 }
    /// Pixels across the whole photo at this image's sharpness.
    public var density: Double { pixelWidth / max(0.0001, Double(region.width)) }
}

/// What the screen asks of the photo now: the part in view, and the pixels across the whole photo
/// it takes to be sharp there (0 at Fit and below, where the 2560 px proxy is sharp enough).
public struct DisplayNeed: Equatable, Sendable {
    public var visible: CGRect
    public var density: Double

    public init(visible: CGRect = DisplayTag.whole, density: Double = 0) {
        self.visible = visible
        self.density = density
    }

    public static let anything = DisplayNeed()
}

/// The one rule for what the Develop photo view shows (Rosh, Nov 21, 2026: "it is drawing low
/// resolution then drawing the high resolution which is very annoying to watch"; "look at this
/// area cleanly"). Every image that could go on the photo view, from every path (the stand-in
/// at open, the proxy, live frames, the zoomed visible-area renders, the full-size image), is
/// offered here with its `DisplayTag`, and the rule alone decides:
///
/// - Never back: an older edit or an earlier photo than what is on screen is dropped.
/// - Never softer: an image that isn't sharp enough for the zoom (`DisplayNeed`) doesn't replace
///   one that is. It waits, and shows only if nothing sharp of its edit or newer arrives in time
///   (`editWait` for an edit of the photo on screen, `openWait` for another photo), so a slow
///   sharp render costs a short lag, never a blur flash.
/// - A visible-area image (`region` not the whole photo) goes over the whole-photo one while it
///   covers what is in view and is at least as new; a whole-photo image as new and sharp takes
///   its place.
///
/// A plain value with no clock or threads of its own, so it can be tested on its own;
/// `PhotoDisplay` in the app applies its decisions to the photo view's layers.
public struct SharpDisplay: Sendable {
    /// The longest a newer edit waits for a sharp image before its soft one shows.
    public static let editWait: TimeInterval = 0.25
    /// The longest another photo waits for a sharp image before its soft one shows.
    public static let openWait: TimeInterval = 1.0

    public enum Layer: Sendable { case base, detail }

    public enum Decision: Equatable, Sendable {
        /// Put it on `layer`; `clearsDetail` also takes the visible-area image off.
        case show(Layer, clearsDetail: Bool)
        /// Hold it: show it at `deadline` unless something better comes first (`expire`).
        case wait(deadline: TimeInterval)
        /// A sharp visible-area image of the photo that is waiting: put the waiting image on the
        /// base layer, under this one on the detail layer, so panning shows that photo too.
        case showOverHeld
        case drop
    }

    public private(set) var base: DisplayTag?
    public private(set) var detail: DisplayTag?
    /// The soft image waiting, and when it shows.
    public private(set) var pending: (tag: DisplayTag, deadline: TimeInterval)?
    public private(set) var need = DisplayNeed.anything

    public init() {}

    /// What is on screen now.
    public var visible: DisplayTag? {
        if let detail, covers(detail.region, need.visible), detail.revision >= (base?.revision ?? .min),
           detail.photo == base?.photo ?? detail.photo { return detail }
        return base
    }

    public func isSharp(_ tag: DisplayTag) -> Bool {
        covers(tag.region, need.visible) && tag.density >= need.density * 0.95
    }

    /// Whether `tag` arriving now would be dropped, without changing anything (lets a renderer
    /// skip work nobody would see).
    public func isWanted(_ tag: DisplayTag) -> Bool {
        guard let shown = visible else { return true }
        return tag.photo > shown.photo || (tag.photo == shown.photo && tag.revision >= shown.revision)
    }

    public mutating func offer(_ tag: DisplayTag, now: TimeInterval) -> Decision {
        // The same image again (SwiftUI hands the view its image with every change it publishes).
        if tag == base || tag == detail { return .drop }
        // A visible-area image made for a spot the view has left.
        if !tag.isWhole, !covers(tag.region, need.visible) { return .drop }
        guard let shown = visible else { return accept(tag) }
        if tag.photo < shown.photo { return .drop }
        if tag.photo > shown.photo {
            // Another photo: shown once sharp, or when its wait is over.
            if isSharp(tag) { return accept(tag) }
            return tag.isWhole ? hold(tag, now: now, wait: Self.openWait) : .drop
        }
        if tag.revision < shown.revision {
            // An older full-size image can still go under a newer visible-area image, where it
            // is seen only when the view pans off it.
            if tag.isWhole, let detail, detail.revision >= tag.revision, tag.revision > (base?.revision ?? .min) {
                base = tag
                return .show(.base, clearsDetail: false)
            }
            return .drop
        }
        if tag.revision == shown.revision {
            // The same edit again: only as sharp or sharper adds anything.
            return tag.density >= shown.density * 0.95 ? accept(tag) : .drop
        }
        if isSharp(tag) || !isSharp(shown) { return accept(tag) }
        return hold(tag, now: now, wait: Self.editWait)
    }

    /// The waiting image's time is up: true when it should show now (then it is on screen).
    public mutating func expire(now: TimeInterval) -> Decision {
        guard let pending, pending.deadline <= now + 0.0005 else { return .drop }
        self.pending = nil
        guard isWanted(pending.tag) else { return .drop }
        return accept(pending.tag)
    }

    /// The view panned or zoomed. True when the visible-area image no longer covers the view
    /// and has to come off.
    public mutating func setNeed(_ need: DisplayNeed) -> Bool {
        self.need = need
        guard let detail, !covers(detail.region, need.visible) else { return false }
        self.detail = nil
        return true
    }

    /// Nothing shown (the view was given another photo source or detached).
    public mutating func reset() {
        base = nil
        detail = nil
        pending = nil
    }

    private mutating func accept(_ tag: DisplayTag) -> Decision {
        if !tag.isWhole, base?.photo != tag.photo {
            // A visible-area image needs its own photo under it: the one waiting, if any.
            guard let pending, pending.tag.photo == tag.photo, pending.tag.isWhole else { return .drop }
            self.base = pending.tag
            self.pending = nil
            detail = tag
            return .showOverHeld
        }
        if let pending, pending.tag.photo < tag.photo || pending.tag.photo == tag.photo && pending.tag.revision <= tag.revision {
            self.pending = nil
        }
        if tag.isWhole {
            let clears = detail.map { detail in
                tag.photo != detail.photo || tag.revision > detail.revision || isSharp(tag) || !covers(detail.region, need.visible)
            } ?? false
            base = tag
            if clears { detail = nil }
            return .show(.base, clearsDetail: clears)
        }
        detail = tag
        return .show(.detail, clearsDetail: false)
    }

    private mutating func hold(_ tag: DisplayTag, now: TimeInterval, wait: TimeInterval) -> Decision {
        // A run of soft images keeps the first one's deadline, so a slow sharp render costs at
        // most `wait`, however many soft frames come in meanwhile.
        let deadline: TimeInterval
        if let pending, pending.tag.photo == tag.photo { deadline = pending.deadline } else { deadline = now + wait }
        if let pending, pending.tag.photo == tag.photo, pending.tag.revision > tag.revision { return .drop }
        pending = (tag, deadline)
        return .wait(deadline: deadline)
    }

    private func covers(_ region: CGRect, _ visible: CGRect) -> Bool {
        let slack = 0.002
        return region.minX <= visible.minX + slack && region.minY <= visible.minY + slack
            && region.maxX >= visible.maxX - slack && region.maxY >= visible.maxY - slack
    }
}
