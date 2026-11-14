import Foundation
import XCTest
@testable import AtelierCore

/// Eyes closed on Rosh's test photos (generated with Gemini, Nov 14, 2026; see `labels.md` in the
/// folder). They aren't in the repository: the test reads `ATELIER_CULL_FIXTURES`, else
/// ~/RoshProjects/Atelier/TestPhotos/Cull, and is skipped when neither exists. It prints every
/// face's eye openness, MediaPipe's blink and smile scores, and each photo's analysis time, for
/// tuning `CullEyes`.
final class CullFixtureTests: XCTestCase {
    private func folder() throws -> URL {
        let path = ProcessInfo.processInfo.environment["ATELIER_CULL_FIXTURES"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("RoshProjects/Atelier/TestPhotos/Cull").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No Cull test photos at \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    /// Analyzes a set's photos (standard and Advanced checks) as one group and returns the eyes
    /// of each photo, faces left to right.
    private func eyes(_ set: String, _ names: [String], file: StaticString = #filePath, line: UInt = #line) async throws -> [String: [CullEyes]] {
        let dir = try folder().appendingPathComponent(set)
        var signals: [CullSignals] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            let start = Date()
            var signal = await Culling.analyze(url)
            let standard = Date().timeIntervalSince(start)
            signal = Culling.analyzeAdvanced(url, signals: signal)
            let advanced = Date().timeIntervalSince(start) - standard
            signal.faces.sort { $0.box.minX < $1.box.minX }
            let openness = signal.faces.map { (face: CullFace) -> String in
                (face.openness.map { String(format: "%.3f", $0) } ?? (face.skip?.rawValue ?? "-"))
                    + (face.expression.map { String(format: " (blink %.2f smile %.2f)", $0.blink, $0.smile) } ?? "")
            }
            print(String(format: "cull fixture %@/%@: standard %.0f ms, advanced %.0f ms, aesthetics %@, eyes %@",
                         set, name, standard * 1000, advanced * 1000,
                         signal.aesthetics.map { String(format: "%.2f", $0) } ?? "-", openness.joined(separator: " ")))
            signals.append(signal)
        }
        let eyes = Culling.eyes(in: signals.map(\.faces))
        for (name, photoEyes) in zip(names, eyes) { print("cull fixture \(set)/\(name): \(photoEyes)") }
        return Dictionary(uniqueKeysWithValues: zip(names, eyes))
    }

    func testGroupOfFive() async throws {
        let eyes = try await self.eyes("group-5-outdoor", ["base.jpg", "one-blink.jpg", "two-blink.jpg", "half-closed.jpg"])
        XCTAssertEqual(eyes["base.jpg"]?.count, 5)
        XCTAssertFalse(eyes["base.jpg"]?.contains(.closed) ?? true)
        XCTAssertEqual(eyes["one-blink.jpg"]?[1], .closed)
        XCTAssertEqual(eyes["two-blink.jpg"]?[2], .closed)
        XCTAssertEqual(eyes["two-blink.jpg"]?[4], .closed)
        XCTAssertNotEqual(eyes["half-closed.jpg"]?[0], .open)
    }

    func testPortraitNarrowEyesAndGlasses() async throws {
        for (set, names) in [("portrait-eyes", ["open.jpg", "closed.jpg", "squint-smile.jpg", "looking-down.jpg"]),
                             ("narrow-eyes", ["open.jpg", "closed.jpg", "smile.jpg"]),
                             ("glasses", ["open.jpg", "closed.jpg", "glare.jpg", "sunglasses.jpg"])] {
            let eyes = try await self.eyes(set, names)
            XCTAssertEqual(eyes["open.jpg"], [.open], set)
            XCTAssertEqual(eyes["closed.jpg"], [.closed], set)
        }
    }

    func testKids() async throws {
        let eyes = try await self.eyes("kids-group", ["base.jpg", "mixed.jpg"])
        XCTAssertEqual(eyes["base.jpg"], [.open, .open, .open])
        XCTAssertEqual(eyes["mixed.jpg"]?[1], .closed)
    }

    /// Profiles and the crowd only print, for tuning: nothing here is certain enough to assert.
    func testProfilesAndCrowdPrint() async throws {
        _ = try await self.eyes("profile-and-small-faces", ["profile.jpg"])
        _ = try await self.eyes("profile-and-small-faces", ["crowd.jpg"])
    }
}
