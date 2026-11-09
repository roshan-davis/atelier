import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    init(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: Self.colorSpace, bitmapInfo: Self.format) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func write(to url: URL) throws {
        guard let data = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4, space: Self.colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: Self.format), provider: data,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
    }

    /// Show changed pixels in pink over a dimmed copy of the new image.
    mutating func highlightDifferences(from before: Bitmap) -> Int {
        var changed = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if (0..<4).contains(where: { pixels[index + $0] != before.pixels[index + $0] }) {
                pixels[index] = 255
                pixels[index + 1] = 45
                pixels[index + 2] = 130
                changed += 1
            } else {
                pixels[index] /= 3
                pixels[index + 1] /= 3
                pixels[index + 2] /= 3
            }
            pixels[index + 3] = 255
        }
        return changed
    }
}

func compare(before: URL, after: URL, output: URL) throws {
    let files = FileManager.default
    func names(in folder: URL) throws -> Set<String> {
        Set(try files.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") })
    }
    let oldNames = try names(in: before)
    let newNames = try names(in: after)
    var differences = 0
    for name in oldNames.union(newNames).sorted() {
        let oldURL = before.appendingPathComponent(name)
        let newURL = after.appendingPathComponent(name)
        let hasBefore = oldNames.contains(name)
        let hasAfter = newNames.contains(name)
        var diff: Bitmap?
        let detail: String
        if hasBefore, hasAfter {
            let old = try Bitmap(oldURL)
            var new = try Bitmap(newURL)
            if old.width != new.width || old.height != new.height {
                detail = "size changed from \(old.width)×\(old.height) to \(new.width)×\(new.height)"
            } else {
                guard old.pixels != new.pixels else { continue }
                let count = new.highlightDifferences(from: old)
                detail = "\(count) pixels changed"
                diff = new
            }
        } else {
            detail = hasAfter ? "added" : "removed"
        }

        print("\(name): \(detail)")
        differences += 1
        let folder = output.appendingPathComponent(String(name.dropLast(4)), isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        if hasBefore { try files.copyItem(at: oldURL, to: folder.appendingPathComponent("before.png")) }
        if hasAfter { try files.copyItem(at: newURL, to: folder.appendingPathComponent("after.png")) }
        try diff?.write(to: folder.appendingPathComponent("diff.png"))
    }
    let total = oldNames.union(newNames).count
    print("\(differences)/\(total) changed" + (differences > 0 ? " (review visual/)" : ""))
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("Usage: compare-snapshots BEFORE AFTER OUTPUT\n".utf8))
    exit(2)
}
do {
    let folders = arguments.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
    try compare(before: folders[0], after: folders[1], output: folders[2])
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
