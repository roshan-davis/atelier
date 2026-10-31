import Foundation
import AtelierHDRCore
import AtelierCore

@main struct Qualification {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--prepare-catalog" {
            let catalog = try Catalog(packageURL: URL(fileURLWithPath: args[2]))
            let result = await Importer(catalog: catalog, previews: nil).run(sources: [URL(fileURLWithPath: args[3])], options: ImportOptions(buildPreviews: false))
            print("Prepared disposable catalog with \(result.assetIDsBySource.count) photos")
            return
        }
        guard args.count >= 3 else { fatalError("Usage: HDRQualification NEW-OUTPUT-DIRECTORY SOURCE...") }
        let output = URL(fileURLWithPath: args[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Output must be new") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let io = HDRImageIO()
        var rows: [[String: String]] = []
        for path in args.dropFirst(2) {
            let source = URL(fileURLWithPath: path), hash = try HDRProjectStore.hash(source)
            let start = Date(), input = try io.decode(source, longEdge: 1200)
            let decode = Date().timeIntervalSince(start)
            for method in HDRMethod.allCases {
                var settings = HDRSettings(); settings.method = method
                let original = output.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-original.tif")
                if !FileManager.default.fileExists(atPath: original.path) { try io.writeTIFF(input, to: original) }
                let renderStart = Date(), rendered = try HDRToneMapper.render(input, settings: settings)
                let render = Date().timeIntervalSince(renderStart)
                let name = source.deletingPathExtension().lastPathComponent + "-" + method.rawValue + ".tif"
                try io.writeTIFF(rendered, to: output.appendingPathComponent(name))
                rows.append(["source": source.lastPathComponent, "sourceSHA256": hash, "method": method.rawValue,
                             "width": "\(input.width)", "height": "\(input.height)",
                             "decodeSeconds": "\(decode)", "renderSeconds": "\(render)"])
            }
            guard try HDRProjectStore.hash(source) == hash else { fatalError("Source changed") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: output.appendingPathComponent("report.json"))
        print(String(data: try encoder.encode(rows), encoding: .utf8)!)
    }
}
