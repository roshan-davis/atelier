import AppKit
import AtelierCore
import SwiftUI

/// The note being typed (AT-058): plain text with the small Markdown set `NoteText` reads,
/// styled as it is typed. Return carries a list on (Return on an empty item ends it), ⇧Return is
/// a plain new line, Tab and ⇧Tab move a list line in and out, ⌘B and ⌘I wrap the selection in
/// `**` and `*`, `[] ` starts a checkbox and `* ` a bullet. Esc and ⌘Return end typing.
struct NoteEditor: NSViewRepresentable {
    let text: String
    let font: NotesFont
    let palette: NotesPalette
    let changed: (String) -> Void
    let finished: () -> Void
    /// Lets the panel's format buttons reach the text view.
    var proxy: NoteEditorProxy?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NoteTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Note")
        scroll.documentView = textView

        textView.string = text
        context.coordinator.restyle(textView)
        proxy?.textView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let styleChanged = coordinator.parent.font != font || coordinator.parent.palette.ink != palette.ink
        coordinator.parent = self
        guard let textView = scroll.documentView as? NoteTextView else { return }
        if textView.string != text {
            // Changed from outside, such as a checkbox ticked in the note: keep the cursor near.
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            coordinator.restyle(textView)
        } else if styleChanged {
            coordinator.restyle(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor

        init(_ parent: NoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            restyle(textView)
            parent.changed(textView.string)
        }

        func finish() { parent.finished() }

        // MARK: Keys

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                finish()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                return continueList(in: textView)
            case #selector(NSResponder.insertTab(_:)):
                return indent(in: textView, by: 1)
            case #selector(NSResponder.insertBacktab(_:)):
                return indent(in: textView, by: -1)
            default:
                return false
            }
        }

        /// `[] `, `[ ] `, `* ` and `• ` typed at the start of a line become a checkbox or bullet.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            guard replacementString == " ", range.length == 0 else { return true }
            let string = textView.string as NSString
            let lineStart = string.lineRange(for: NSRange(location: range.location, length: 0)).location
            let typedRange = NSRange(location: lineStart, length: range.location - lineStart)
            let typed = string.substring(with: typedRange) + " "
            guard let becomes = NoteText.typedShortcut(typed) else { return true }
            replace(typedRange, with: becomes, in: textView)
            return false
        }

        private func currentLine(in textView: NSTextView) -> (range: NSRange, text: String) {
            let string = textView.string as NSString
            var range = string.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
            let line = string.substring(with: range)
            if line.hasSuffix("\n") { range.length -= 1 }
            return (range, string.substring(with: range))
        }

        private func continueList(in textView: NSTextView) -> Bool {
            let selection = textView.selectedRange()
            let line = currentLine(in: textView)
            switch NoteText.continuation(after: line.text) {
            case .newLine:
                return false
            case .continueWith(let prefix):
                textView.insertText("\n" + prefix, replacementRange: selection)
                return true
            case .endList:
                replace(line.range, with: "", in: textView)
                return true
            }
        }

        private func indent(in textView: NSTextView, by step: Int) -> Bool {
            let line = currentLine(in: textView)
            guard NoteText.line(line.text).marker != .none else { return step > 0 ? false : true }
            let moved = NoteText.indented(line.text, by: step)
            guard moved != line.text else { return true }
            let cursor = textView.selectedRange().location - line.range.location
            let shift = (moved as NSString).length - (line.text as NSString).length
            replace(line.range, with: moved, in: textView)
            let location = line.range.location + max(cursor + shift, 0)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            return true
        }

        /// The panel's list buttons: the selected lines become a list of that kind, or plain again.
        func toggleList(_ kind: NoteText.ListKind, in textView: NSTextView) {
            let string = textView.string as NSString
            var range = string.lineRange(for: textView.selectedRange())
            if string.substring(with: range).hasSuffix("\n") { range.length -= 1 }
            let lines = string.substring(with: range).components(separatedBy: "\n")
            let toggled = NoteText.togglingList(kind, lines: lines).joined(separator: "\n")
            replace(range, with: toggled, in: textView)
        }

        /// ⌘B and ⌘I: wraps the selection in `**` or `*` (or takes them off again).
        func wrapSelection(in textView: NSTextView, with mark: String) {
            let range = textView.selectedRange()
            let string = textView.string as NSString
            let selected = string.substring(with: range)
            let length = (mark as NSString).length
            if selected.hasPrefix(mark), selected.hasSuffix(mark), (selected as NSString).length >= 2 * length {
                let inner = (selected as NSString).substring(with: NSRange(location: length,
                                                                          length: (selected as NSString).length - 2 * length))
                replace(range, with: inner, in: textView)
                textView.setSelectedRange(NSRange(location: range.location, length: (inner as NSString).length))
            } else {
                replace(range, with: mark + selected + mark, in: textView)
                textView.setSelectedRange(NSRange(location: range.location + length, length: range.length))
            }
        }

        /// One undoable change, as typing makes.
        private func replace(_ range: NSRange, with text: String, in textView: NSTextView) {
            guard textView.shouldChangeText(in: range, replacementString: text) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: text)
            textView.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
            textView.didChangeText()
        }

        // MARK: Styling

        /// Markers and `**`/`*` are dimmed but stay visible, so what is typed is what is saved.
        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let base = parent.font.nsFont()
            let bold = parent.font.nsFont(bold: true)
            let ink = parent.palette.ink
            let faint = parent.palette.faint
            let string = storage.string as NSString
            let whole = NSRange(location: 0, length: string.length)

            textView.insertionPointColor = ink
            textView.typingAttributes = [.font: base, .foregroundColor: ink]
            storage.beginEditing()
            storage.setAttributes([.font: base, .foregroundColor: ink], range: whole)
            var location = 0
            while location < string.length {
                let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
                var contentRange = lineRange
                let raw = string.substring(with: lineRange)
                if raw.hasSuffix("\n") { contentRange.length -= 1 }
                let lineText = string.substring(with: contentRange)
                let parsed = NoteText.line(lineText)
                let markerLength = (lineText as NSString).length - (parsed.content as NSString).length
                if parsed.marker != .none, markerLength > 0 {
                    storage.addAttribute(.foregroundColor, value: faint,
                                         range: NSRange(location: contentRange.location, length: markerLength))
                    if parsed.marker == .checkbox(checked: true) {
                        let done = NSRange(location: contentRange.location + markerLength,
                                           length: contentRange.length - markerLength)
                        storage.addAttributes([.foregroundColor: faint,
                                               .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: done)
                    }
                }
                location = NSMaxRange(lineRange)
                if lineRange.length == 0 { break }
            }
            for match in Self.bold.matches(in: storage.string, range: whole) {
                storage.addAttribute(.font, value: bold, range: match.range(at: 2))
                storage.addAttribute(.foregroundColor, value: faint, range: match.range(at: 1))
                storage.addAttribute(.foregroundColor, value: faint, range: match.range(at: 3))
            }
            for match in Self.italic.matches(in: storage.string, range: whole) {
                storage.addAttribute(.obliqueness, value: 0.18, range: match.range(at: 2))
                storage.addAttribute(.foregroundColor, value: faint, range: match.range(at: 1))
                storage.addAttribute(.foregroundColor, value: faint, range: match.range(at: 3))
            }
            storage.endEditing()
        }

        private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#)
        private static let italic = try! NSRegularExpression(
            pattern: #"(?<![\*\w])([\*_])(?![\*\s])(.+?)(?<![\*\s])(\1)(?![\*\w])"#)
    }
}

/// The panel's format buttons act on the note being typed through this.
@MainActor
final class NoteEditorProxy {
    weak var textView: NoteTextView?

    func toggleList(_ kind: NoteText.ListKind) {
        guard let textView, let coordinator = textView.coordinator else { return }
        textView.window?.makeFirstResponder(textView)
        coordinator.toggleList(kind, in: textView)
    }

    func wrap(_ mark: String) {
        guard let textView, let coordinator = textView.coordinator else { return }
        textView.window?.makeFirstResponder(textView)
        coordinator.wrapSelection(in: textView, with: mark)
    }
}

/// The text view inside `NoteEditor`. Library's and Cull's own keys leave it alone while it is
/// typing (see `LibraryModel.handleKey` and `CullKeyMonitor`).
final class NoteTextView: NSTextView {
    weak var coordinator: NoteEditor.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let coordinator else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Esc ends typing before a sheet's Cancel button (Cull) can take it.
        if event.keyCode == 53, flags.intersection([.command, .control, .option, .shift]).isEmpty {
            coordinator.finish()
            return true
        }
        if flags == .command {
            if event.keyCode == 36 || event.keyCode == 76 { // Return, Enter
                coordinator.finish()
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b":
                coordinator.wrapSelection(in: self, with: "**")
                return true
            case "i":
                coordinator.wrapSelection(in: self, with: "*")
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
