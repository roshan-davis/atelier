import AtelierCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct QualificationError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

func renderPresets() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else {
        throw QualificationError("Usage: swift run PresetQualification OUT_DIR PHOTO [PHOTO ...]")
    }
    let output = URL(fileURLWithPath: args[0], isDirectory: true)
    let presets = DevelopPreset.builtIn
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let catalog = try encoder.encode(presets)
    try catalog.write(to: output.appendingPathComponent("presets.json"))

    var sceneNames = Set<String>()
    for path in args.dropFirst() {
        let photo = URL(fileURLWithPath: path)
        let scene = photo.deletingPathExtension().lastPathComponent
        guard sceneNames.insert(scene).inserted else { throw QualificationError("Duplicate scene: \(scene)") }
        guard let session = DevelopRenderer.shared.session(for: photo, maxPixelSize: 1200) else {
            throw QualificationError("Unable to open \(photo.path)")
        }
        let folder = output.appendingPathComponent(scene, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(session, .neutral, to: folder.appendingPathComponent("before.jpg"))
        for preset in presets {
            let url = folder.appendingPathComponent("\(preset.id.uuidString).jpg")
            try write(session, preset.applied(to: .neutral), to: url)
        }
        print("\(scene): before and \(presets.count) presets")
    }
}

func write(_ session: DevelopSession, _ settings: DevelopSettings, to url: URL) throws {
    guard let image = session.renderSRGB(settings),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw QualificationError("Unable to render \(url.path)") }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw QualificationError("Unable to save \(url.path)") }
}

try renderPresets()
