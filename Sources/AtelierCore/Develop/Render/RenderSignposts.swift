import Foundation
import os

/// Timing marks for the render path, shown in Instruments' Points of Interest (AGENTS.md:
/// measure before optimizing). They cost next to nothing when Instruments isn't recording.
public enum RenderSignposts {
    static let signposter = OSSignposter(subsystem: "Atelier", category: .pointsOfInterest)

    /// Runs `body` inside a named interval.
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        try signposter.withIntervalSignpost(name, id: signposter.makeSignpostID()) { try body() }
    }
}
