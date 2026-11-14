import Foundation
import XCTest

/// `.onTapGesture(count: 2)` holds back every single click on the view, and on views around it,
/// for the double-click time. Double-clicks go through `onClick(perform:doubleClick:)` or
/// `onDoubleClick(perform:)` (Views/ClickGestures.swift), which never delay a single click.
final class ClickGestureTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A double-tap with truly nothing taking a single click says why, on the line above,
    /// with `// double-click only: <reason>`.
    func testNoDoubleTapGestureDelaysASingleClick() throws {
        let sources = Self.root.appendingPathComponent("Sources/AtelierApp")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains("onTapGesture(count: 2") else { continue }
                if index > 0, lines[index - 1].contains("// double-click only:") { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): \(code)")
            }
        }
        XCTAssertEqual(offenders, [], "Use .onClick(perform:doubleClick:) or .onDoubleClick(perform:)")
    }
}
