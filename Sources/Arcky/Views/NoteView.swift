import AppKit
import SwiftUI

/// Arc-style Note: a title and a rich-text body. Typing "# ", "- " or "[] " at the start of a
/// line makes a heading, bullet or checkbox; Return continues a list; clicking a box ticks it.
struct NoteView: View {
    let noteID: UUID
    @Environment(BrowserStore.self) private var store
    @State private var editor = NoteEditorController()

    private var documents: DocumentStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Untitled Note", text: Binding(
                get: { documents.notes[noteID]?.title ?? "" },
                set: { title in
                    documents.updateNote(noteID) { $0.title = title }
                    store.syncDocumentTitle(.note(noteID), title: title)
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 30, weight: .bold))
            .onSubmit { editor.focusBody() }
            .padding(.bottom, 10)

            NoteToolbar(editor: editor)
                .padding(.bottom, 8)
            Divider()

            NoteTextEditor(noteID: noteID, controller: editor)
        }
        .padding(.horizontal, 48)
        .padding(.top, 36)
        .frame(maxWidth: 860, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct NoteToolbar: View {
    let editor: NoteEditorController

    var body: some View {
        HStack(spacing: 2) {
            button("textformat.size.larger", "Heading") { editor.toggleHeading() }
            button("bold", "Bold (⌘B)") { editor.toggleTrait(.boldFontMask) }
            button("italic", "Italic (⌘I)") { editor.toggleTrait(.italicFontMask) }
            button("strikethrough", "Strikethrough") { editor.toggleStrikethrough() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("list.bullet", "Bulleted List") { editor.toggleLinePrefix(NoteEditorController.bullet) }
            button("checklist", "Checklist") { editor.toggleLinePrefix(NoteEditorController.unchecked) }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func button(_ systemImage: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .help(help)
    }
}

/// Formatting commands for the note's text view.
@MainActor
final class NoteEditorController {
    static let bullet = "•\u{00A0}"
    static let unchecked = "☐\u{00A0}"
    static let checked = "☑\u{00A0}"
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let headingFont = NSFont.systemFont(ofSize: 22, weight: .bold)

    weak var textView: NSTextView?

    func focusBody() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    private func edit(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let textView, let storage = textView.textStorage,
              textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        textView.didChangeText()
    }

    private var selectedParagraphs: NSRange? {
        guard let textView else { return nil }
        return (textView.string as NSString).paragraphRange(for: textView.selectedRange())
    }

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            // No selection: change what gets typed next.
            let font = textView.typingAttributes[.font] as? NSFont ?? Self.bodyFont
            textView.typingAttributes[.font] = Self.toggled(font, trait)
            return
        }
        edit(range) { storage in
            let firstFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? Self.bodyFont
            let adding = !NSFontManager.shared.traits(of: firstFont).contains(trait)
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = value as? NSFont ?? Self.bodyFont
                let manager = NSFontManager.shared
                let newFont = adding ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
                storage.addAttribute(.font, value: newFont, range: subrange)
            }
        }
    }

    private static func toggled(_ font: NSFont, _ trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        return manager.traits(of: font).contains(trait) ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
    }

    func toggleStrikethrough() {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        edit(range) { storage in
            let struck = (storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
            if struck {
                storage.removeAttribute(.strikethroughStyle, range: range)
            } else {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    func toggleHeading() {
        guard let range = selectedParagraphs else { return }
        edit(range) { storage in
            let current = storage.length > range.location ? storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : nil
            let isHeading = (current?.pointSize ?? 0) >= Self.headingFont.pointSize
            storage.addAttribute(.font, value: isHeading ? Self.bodyFont : Self.headingFont, range: range)
        }
        textView?.typingAttributes[.font] = Self.bodyFont
    }

    /// Adds `prefix` to every selected line, or removes list markers if all lines already have one.
    func toggleLinePrefix(_ prefix: String) {
        guard let textView, let range = selectedParagraphs else { return }
        let text = textView.string as NSString
        var lines: [NSRange] = []
        text.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, lineRange, _, _ in
            lines.append(lineRange)
        }
        if lines.isEmpty { lines = [NSRange(location: range.location, length: 0)] }
        let allHave = lines.allSatisfy { Self.marker(in: text, at: $0.location) != nil }
        edit(range) { storage in
            // Back to front, so earlier ranges stay valid.
            for line in lines.reversed() {
                if let existing = Self.marker(in: storage.string as NSString, at: line.location) {
                    storage.replaceCharacters(in: NSRange(location: line.location, length: (existing as NSString).length), with: "")
                }
                if !allHave {
                    storage.insert(NSAttributedString(string: prefix, attributes: [.font: Self.bodyFont]), at: line.location)
                }
            }
        }
    }

    /// Text colours are never saved: notes get the adaptive text colour (so they read in light
    /// and dark mode), and ticked checklist items are greyed.
    static func applyColors(to storage: NSTextStorage) {
        let all = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: all)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: all)
        let text = storage.string as NSString
        text.enumerateSubstrings(in: all, options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
            if marker(in: text, at: line.location) == checked {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line)
            }
        }
    }

    /// The list marker at the start of a line, if any.
    static func marker(in text: NSString, at location: Int) -> String? {
        for marker in [bullet, unchecked, checked] where location + (marker as NSString).length <= text.length {
            if text.substring(with: NSRange(location: location, length: (marker as NSString).length)) == marker { return marker }
        }
        return nil
    }
}

/// The note body: an NSTextView whose content is saved as RTFD on every change.
private struct NoteTextEditor: NSViewRepresentable {
    let noteID: UUID
    let controller: NoteEditorController

    func makeCoordinator() -> Coordinator { Coordinator(noteID: noteID) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let textView = NoteTextView(frame: .zero)
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 0, height: 14)
        textView.font = NoteEditorController.bodyFont
        textView.textColor = .textColor
        textView.typingAttributes = [.font: NoteEditorController.bodyFont, .foregroundColor: NSColor.textColor]
        if let body = DocumentStore.shared.notes[noteID]?.body, !body.isEmpty,
           let text = NSAttributedString(rtfd: body, documentAttributes: nil), let storage = textView.textStorage {
            storage.setAttributedString(text)
            NoteEditorController.applyColors(to: storage)
        }
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        controller.textView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        controller.textView = scrollView.documentView as? NSTextView
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let noteID: UUID
        weak var textView: NSTextView?

        init(noteID: UUID) {
            self.noteID = noteID
        }

        func textDidChange(_ notification: Notification) {
            guard let storage = textView?.textStorage else { return }
            // Saved without colours; they're reapplied on load.
            let copy = NSMutableAttributedString(attributedString: storage)
            copy.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: copy.length))
            let data = copy.rtfd(from: NSRange(location: 0, length: copy.length), documentAttributes: [:]) ?? Data()
            DocumentStore.shared.updateNote(noteID) { $0.body = data }
        }

        /// Links open in a new tab.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            BrowserStore.shared.open(url, inNewTab: true)
            return true
        }

        /// Markdown-style shortcuts at the start of a line, and list continuation on Return.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString, range.length == 0 else { return true }
            let text = textView.string as NSString
            let line = text.paragraphRange(for: NSRange(location: range.location, length: 0))
            let beforeCursor = text.substring(with: NSRange(location: line.location, length: range.location - line.location))

            if replacement == " " {
                let conversion: String? = switch beforeCursor {
                case "-", "*": NoteEditorController.bullet
                case "[]", "[ ]": NoteEditorController.unchecked
                case "#": ""
                default: nil
                }
                guard let conversion else { return true }
                let typed = NSRange(location: line.location, length: (beforeCursor as NSString).length)
                replace(typed, with: conversion, in: textView)
                if beforeCursor == "#" {
                    textView.typingAttributes[.font] = NoteEditorController.headingFont
                }
                return false
            }

            if replacement == "\n" {
                // A heading line ends with body text on the next line.
                if let font = textView.typingAttributes[.font] as? NSFont, font.pointSize >= NoteEditorController.headingFont.pointSize {
                    textView.typingAttributes[.font] = NoteEditorController.bodyFont
                    replace(range, with: "\n", in: textView)
                    return false
                }
                guard let marker = NoteEditorController.marker(in: text, at: line.location) else { return true }
                let markerLength = (marker as NSString).length
                if (beforeCursor as NSString).length == markerLength,
                   line.location + markerLength >= NSMaxRange(line) - (text.substring(with: line).hasSuffix("\n") ? 1 : 0) {
                    // Return on an empty list item ends the list.
                    replace(NSRange(location: line.location, length: markerLength), with: "", in: textView)
                    return false
                }
                let next = marker == NoteEditorController.checked ? NoteEditorController.unchecked : marker
                replace(range, with: "\n" + next, in: textView)
                return false
            }
            return true
        }

        private func replace(_ range: NSRange, with string: String, in textView: NSTextView) {
            guard textView.shouldChangeText(in: range, replacementString: string) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: textView.typingAttributes))
            textView.setSelectedRange(NSRange(location: range.location + (string as NSString).length, length: 0))
            textView.didChangeText()
        }
    }
}

/// Toggles checkboxes when they're clicked.
private final class NoteTextView: NSTextView {
    /// Always at least as tall as the visible area, so clicking below the text starts typing.
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let visibleHeight = enclosingScrollView?.contentView.bounds.height {
            size.height = max(size.height, visibleHeight)
        }
        super.setFrameSize(size)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = string as NSString
        let line = text.paragraphRange(for: NSRange(location: min(index, text.length), length: 0))
        if let marker = NoteEditorController.marker(in: text, at: line.location),
           marker != NoteEditorController.bullet, index <= line.location + 1 {
            let toggled = marker == NoteEditorController.unchecked ? NoteEditorController.checked : NoteEditorController.unchecked
            let range = NSRange(location: line.location, length: (marker as NSString).length)
            if shouldChangeText(in: range, replacementString: toggled) {
                textStorage?.replaceCharacters(in: range, with: toggled)
                // Ticked items are struck through, like a finished to-do.
                let rest = NSRange(location: NSMaxRange(range), length: NSMaxRange(line) - NSMaxRange(range))
                if toggled == NoteEditorController.checked {
                    textStorage?.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: rest)
                } else {
                    textStorage?.removeAttribute(.strikethroughStyle, range: rest)
                    textStorage?.addAttribute(.foregroundColor, value: NSColor.textColor, range: rest)
                }
                didChangeText()
            }
            return
        }
        super.mouseDown(with: event)
    }
}
