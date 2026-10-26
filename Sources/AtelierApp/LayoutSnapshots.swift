import AppKit
import AtelierCore
import SwiftUI

/// Renders the main window in Develop at a few window sizes to images, so layout can be checked
/// on CI without a person at the Mac. Runs when ATELIER_SNAPSHOTS names an output folder.
@MainActor
enum LayoutSnapshots {
    static let sizes: [CGSize] = [CGSize(width: 1000, height: 640), CGSize(width: 1280, height: 800),
                                  CGSize(width: 1728, height: 1117)]

    static var outputFolder: URL? {
        ProcessInfo.processInfo.environment["ATELIER_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: LibraryModel, into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let panels = ["histogram"] + DevelopSettings.Panel.allCases.map(\.rawValue)
        UserDefaults.standard.set(panels.joined(separator: ","), forKey: "develop.expandedPanels")
        UserDefaults.standard.removeObject(forKey: "panel.width")
        model.mode = .develop
        for size in sizes {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: ContentView().environmentObject(model))
            window.contentView = host
            window.setContentSize(size)
            window.orderFront(nil)
            // Let SwiftUI lay out and AppKit controls settle.
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "develop-\(Int(size.width))x\(Int(size.height))"
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent(name + ".png"))
                // A small JPEG too, printed to the log so it can be read without downloading artifacts.
                if let jpeg = smallJPEG(rep, width: 900) {
                    print("SNAPSHOT-BEGIN \(name)")
                    print(jpeg.base64EncodedString())
                    print("SNAPSHOT-END \(name)")
                }
            }
            window.orderOut(nil)
        }
        fflush(stdout)
        exit(0)
    }

    private static func smallJPEG(_ rep: NSBitmapImageRep, width: CGFloat) -> Data? {
        guard let cgImage = rep.cgImage else { return nil }
        let scale = min(1, width / CGFloat(cgImage.width))
        let size = CGSize(width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let small = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
