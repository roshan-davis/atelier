import Foundation

/// The small Markdown subset photo notes are written in (AT-058): `- ` bullets, `1. ` numbered
/// items, `- [ ] ` / `- [x] ` checkboxes, two spaces per indent level (two levels at most),
/// `**bold**`, `*italic*` and links. A note is stored as this plain text, so XMP, search and chat
/// apps read and write ordinary text, and it still reads well where it isn't drawn formatted.
/// The notes panel draws it (`lines`) and helps type it (`continuation`, `typedShortcut`,
/// `indented`); the inline styles are drawn by the app.
public enum NoteText {
    /// The deepest indent: two levels below the first.
    public static let maxIndent = 2
    static let indentUnit = "  "

    public enum Marker: Hashable, Sendable {
        case none
        case bullet
        case numbered(Int)
        case checkbox(checked: Bool)
    }

    /// One line of a note.
    public struct Line: Hashable, Sendable {
        /// 0 to `maxIndent`.
        public var indent: Int
        public var marker: Marker
        /// The text after the marker, with inline Markdown left in.
        public var content: String

        public init(indent: Int = 0, marker: Marker = .none, content: String) {
            self.indent = indent
            self.marker = marker
            self.content = content
        }

        /// The line written out again.
        public var source: String {
            String(repeating: NoteText.indentUnit, count: indent) + NoteText.prefix(for: marker) + content
        }
    }

    public static func prefix(for marker: Marker) -> String {
        switch marker {
        case .none: return ""
        case .bullet: return "- "
        case .numbered(let number): return "\(number). "
        case .checkbox(let checked): return checked ? "- [x] " : "- [ ] "
        }
    }

    /// Trims blank lines and spaces at the start and end; the text in between is kept as typed.
    public static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads one line. Tabs count as one indent level each.
    public static func line(_ raw: some StringProtocol) -> Line {
        var rest = Substring(raw.replacingOccurrences(of: "\t", with: indentUnit))
        var spaces = 0
        while rest.first == " " {
            spaces += 1
            rest = rest.dropFirst()
        }
        let indent = min(spaces / 2, maxIndent)
        for (pattern, checked) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false),
                                   ("* [x] ", true)] where rest.hasPrefix(pattern) {
            return Line(indent: indent, marker: .checkbox(checked: checked), content: String(rest.dropFirst(pattern.count)))
        }
        for bullet in ["- ", "* ", "• "] where rest.hasPrefix(bullet) {
            return Line(indent: indent, marker: .bullet, content: String(rest.dropFirst(bullet.count)))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, let number = Int(digits) {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return Line(indent: indent, marker: .numbered(number), content: String(after.dropFirst(2)))
            }
        }
        // Plain text keeps its own spaces.
        return Line(indent: 0, marker: .none, content: String(raw))
    }

    /// Every line of a note, in order.
    public static func lines(_ text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line($0) }
    }

    /// The note with checkbox number `index` (counted among the lines, from 0) ticked or unticked.
    /// Any other line, or an index out of range, leaves the text as it is.
    public static func togglingCheckbox(atLine index: Int, in text: String) -> String {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard all.indices.contains(index) else { return text }
        var parsed = line(all[index])
        guard case .checkbox(let checked) = parsed.marker else { return text }
        parsed.marker = .checkbox(checked: !checked)
        all[index] = parsed.source
        return all.joined(separator: "\n")
    }

    /// Whether the note has a checkbox that isn't ticked (Library's "Has unticked checkboxes").
    public static func hasOpenCheckbox(_ text: String) -> Bool {
        lines(text).contains { $0.marker == .checkbox(checked: false) }
    }

    /// What Return does at the end of `line` while typing.
    public enum Continuation: Equatable, Sendable {
        /// An ordinary new line.
        case newLine
        /// Start the next line with this (the same kind of item; the next number; an empty box).
        case continueWith(String)
        /// Return on an empty item ends the list: the line's marker is taken off instead.
        case endList
    }

    public static func continuation(after raw: some StringProtocol) -> Continuation {
        let parsed = line(raw)
        switch parsed.marker {
        case .none:
            return .newLine
        case _ where parsed.content.trimmingCharacters(in: .whitespaces).isEmpty:
            return .endList
        case .bullet, .checkbox:
            let next = parsed.marker == .bullet ? Marker.bullet : .checkbox(checked: false)
            return .continueWith(Line(indent: parsed.indent, marker: next, content: "").source)
        case .numbered(let number):
            return .continueWith(Line(indent: parsed.indent, marker: .numbered(number + 1), content: "").source)
        }
    }

    /// A shortcut just typed at the start of a line, and what it becomes: `[] ` starts a
    /// checkbox, `* ` and `• ` a bullet. Nil when the line doesn't start with one.
    public static func typedShortcut(_ raw: some StringProtocol) -> String? {
        let text = String(raw)
        let spaces = text.prefix { $0 == " " }
        let rest = text.dropFirst(spaces.count)
        for (typed, becomes) in [("[] ", "- [ ] "), ("[ ] ", "- [ ] "), ("* ", "- "), ("• ", "- ")]
            where rest.hasPrefix(typed) {
            return String(spaces) + becomes + String(rest.dropFirst(typed.count))
        }
        return nil
    }

    /// The line one level further in (`by: 1`) or out (`by: -1`). Plain lines and lines already
    /// at the limit stay as they are.
    public static func indented(_ raw: some StringProtocol, by step: Int) -> String {
        var parsed = line(raw)
        guard parsed.marker != .none else { return String(raw) }
        parsed.indent = min(max(parsed.indent + step, 0), maxIndent)
        return parsed.source
    }

    /// The words without list markers or `**`/`*`/`_` around them, for one-line summaries.
    public static func plain(_ text: String) -> String {
        lines(text).map { line in
            line.content.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "*", with: "")
        }
        .joined(separator: "\n")
    }
}
