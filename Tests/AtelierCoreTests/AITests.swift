import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AtelierCore

/// A stand-in ComfyUI: accepts uploads and prompts, reports one saved image, serves white.
final class MockComfy: URLProtocol {
    static var queued: [[String: Any]] = []
    static var white: Data = {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return AIImaging.pngData(context.makeImage()!)!
    }()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 8188 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        var body = Data("{}".utf8)
        switch path {
        case "/upload/image":
            body = Data(#"{"name": "in.png", "subfolder": "", "type": "input"}"#.utf8)
        case "/prompt":
            if let json = (try? JSONSerialization.jsonObject(with: Self.read(request))) as? [String: Any],
               let prompt = json["prompt"] as? [String: Any] {
                Self.queued.append(prompt)
            }
            body = Data(#"{"prompt_id": "p1", "number": 1, "node_errors": {}}"#.utf8)
        case "/history/p1":
            body = Data(#"{"p1": {"outputs": {"9": {"images": [{"filename": "out.png", "subfolder": "", "type": "output"}]}}, "status": {"completed": true, "status_str": "success"}}}"#.utf8)
        case "/view":
            body = Self.white
        default:
            break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class AITests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierAI-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        MockComfy.queued = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func client() -> ComfyClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockComfy.self]
        return ComfyClient(baseURL: AISettings.defaultServer, session: URLSession(configuration: configuration))
    }

    func testBinderFillsInputsByTitle() throws {
        let graph = try AIRecipe.removeObject.workflow().graph
        let bound = try WorkflowBinder.bind(graph, values: ["Atelier Prompt": ["text": "sand", "prompt": "sand"], "Atelier Sampler": ["seed": 7]],
                                            required: ["Atelier Prompt"])
        let prompt = (bound["9"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual(prompt?["prompt"] as? String, "sand", "Qwen's encoder takes the prompt as `prompt`")
        XCTAssertNil(prompt?["text"], "inputs the node doesn't have are skipped")
        XCTAssertEqual(((bound["15"] as? [String: Any])?["inputs"] as? [String: Any])?["seed"] as? Int, 7)
        // The clip link is untouched.
        XCTAssertEqual((prompt?["clip"] as? [Any])?.first as? String, "2")
        XCTAssertThrowsError(try WorkflowBinder.bind(graph, values: [:], required: ["Atelier Nothing"]))
    }

    func testBuiltInEditModelsArePermissive() {
        for recipe in [AIRecipe.removeObject, .replaceBackground] {
            XCTAssertFalse(recipe.builtInModels.isEmpty)
            XCTAssertTrue(recipe.builtInModels.allSatisfy { $0.license == "Apache-2.0" && $0.allowedUse == .commercial })
            let graph = (try? recipe.workflow().graph) ?? [:]
            let files = graph.values.compactMap { ($0 as? [String: Any])?["inputs"] as? [String: Any] }
                .flatMap { $0.values.compactMap { $0 as? String } }
            for model in recipe.builtInModels { XCTAssertTrue(files.contains(model.file), "\(model.file) is in the workflow") }
        }
        XCTAssertTrue(AIRecipe.removeObject.instruction(for: "").hasPrefix("Remove the red area and fill it"))
        XCTAssertTrue(AIRecipe.removeObject.instruction(for: "a tree").hasPrefix("Remove the red area, which covered a tree, and fill it"))
        XCTAssertEqual(AIRecipe.replaceBackground.instruction(for: "a beach at dusk"),
                       "Replace the background with a beach at dusk. Keep the subject exactly as it is.")
    }

    func testMaskBoundsAndRegion() throws {
        let stroke = BrushStroke(points: [CGPoint(x: 0.5, y: 0.25)], radius: 0.05)
        let mask = try XCTUnwrap(AIImaging.mask(from: [stroke], width: 400, height: 200))
        let box = try XCTUnwrap(AIImaging.bounds(of: mask))
        XCTAssertEqual(box.midX, 200, accuracy: 2)
        XCTAssertEqual(box.midY, 50, accuracy: 2)
        XCTAssertEqual(box.width, 40, accuracy: 2)
        let region = AIImaging.contextRegion(around: box, imageSize: CGSize(width: 400, height: 200))
        XCTAssertTrue(region.contains(box))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 200).contains(region))
        let work = AIImaging.workSize(for: region.size, longEdge: 1024)
        XCTAssertEqual(Int(work.width) % 8, 0)
        XCTAssertEqual(Int(work.height) % 8, 0)
        XCTAssertEqual(max(work.width, work.height), 1024)
    }

    func testRemoveObjectChangesOnlyThePaintedArea() async throws {
        let source = workDir.appendingPathComponent("Beach.jpg")
        try makeJPEG(at: source, width: 400, height: 300)
        let catalog = try Catalog()
        let imported = await Importer(catalog: catalog, previews: nil)
            .run(sources: [source], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(imported.importedAssetIDs.first)

        let request = AIRequest(recipe: .removeObject, strokes: [BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.06)],
                                seed: 42)
        let result = try await AIRunner(catalog: catalog, client: client())
            .run(request, on: id, settings: AISettings(editModel: "my-edit.gguf"))
        XCTAssertEqual(result.url.lastPathComponent, "Beach-AI Remove Object.tif")

        let workflow = try XCTUnwrap(MockComfy.queued.first)
        let inputs = { (node: String) in (workflow[node] as? [String: Any])?["inputs"] as? [String: Any] }
        XCTAssertEqual(inputs("1")?["unet_name"] as? String, "my-edit.gguf")
        XCTAssertEqual(inputs("15")?["seed"] as? Int, 42)
        XCTAssertEqual(inputs("9")?["prompt"] as? String, AIRecipe.removeObject.instruction(for: ""))
        // The model's reference is the photo with the painted area filled, not the photo itself.
        XCTAssertEqual((inputs("9")?["image1"] as? [Any])?.first as? String, "20")
        XCTAssertEqual((inputs("20")?["mask"] as? [Any])?.first as? String, "8")
        // The reference latent is the filled image at the generation size, not Qwen's 1 MP rescale.
        XCTAssertNil(inputs("9")?["vae"])
        XCTAssertEqual((inputs("21")?["pixels"] as? [Any])?.first as? String, "20")
        XCTAssertEqual((inputs("11")?["conditioning"] as? [Any])?.first as? String, "22")

        let image = try XCTUnwrap(AIImaging.image(at: result.url))
        XCTAssertEqual(image.width, 400)
        XCTAssertGreaterThan(try luminance(image, x: 200, y: 150), 0.9, "the painted spot is filled")
        XCTAssertLessThan(try luminance(image, x: 20, y: 20), 0.45, "the rest is untouched")

        let row = try XCTUnwrap(catalog.assetRows(filter: LibraryFilter()).first { $0.id == result.assetID })
        XCTAssertEqual(row.stackParentId, id)
        XCTAssertEqual(row.stackKind, .ai)
        let provenance = try XCTUnwrap(catalog.derivation(of: result.assetID)?.provenance)
        XCTAssertTrue(provenance.contains("\"seed\":42"))
        XCTAssertTrue(provenance.contains("\"license\":\"unknown\""), "a swapped edit model's license is unknown")
        XCTAssertTrue(provenance.contains("Apache-2.0"), "the rest of the built-in models are recorded")
    }

    func testUpscaleAsksForTheChosenFactor() async throws {
        let source = workDir.appendingPathComponent("Small.jpg")
        try makeJPEG(at: source, width: 120, height: 80)
        let catalog = try Catalog()
        let imported = await Importer(catalog: catalog, previews: nil)
            .run(sources: [source], options: ImportOptions(buildPreviews: false))
        let id = try XCTUnwrap(imported.importedAssetIDs.first)
        _ = try await AIRunner(catalog: catalog, client: client())
            .run(AIRequest(recipe: .upscale), on: id, settings: AISettings(upscaleFactor: 2))
        let workflow = try XCTUnwrap(MockComfy.queued.first)
        let scale = ((workflow["4"] as? [String: Any])?["inputs"] as? [String: Any])?["scale_by"] as? Double
        XCTAssertEqual(scale, 0.5)
    }

    private func luminance(_ image: CGImage, x: Int, y: Int) throws -> Double {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / (3 * 255)
    }

    private func makeJPEG(at url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.3, 0.3, 0.3, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
