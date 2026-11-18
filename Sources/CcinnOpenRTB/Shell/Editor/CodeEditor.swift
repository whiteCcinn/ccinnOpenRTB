import AppKit
import SwiftUI

/// A plain-text code editor (`NSTextView`) for JSON / XML with highlighting computed off the main thread, so a 1 MB
/// response stays responsive: typing never waits for the highlighter, and a stale highlight result is dropped.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var accessibilityLabel: String
    /// `false` for a viewer (a response): selectable and searchable, not editable.
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = isEditable
        textView.allowsUndo = isEditable
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = CodeEditor.font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.scheduleHighlight(immediately: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, !context.coordinator.isEditing else { return }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            textView.allowsUndo = isEditable
        }
        // Programmatic changes (samples, Format, Clear): replace the text, keep it undoable.
        guard textView.string != text else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        // The change comes from the binding: it must not be echoed back into it (that would supersede work the owner is
        // doing with this very text, such as parsing a sample).
        context.coordinator.isApplyingBinding = true
        if textView.shouldChangeText(in: range, replacementString: text) {
            textView.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        } else {
            textView.string = text
        }
        context.coordinator.isApplyingBinding = false
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        context.coordinator.scheduleHighlight(immediately: true)
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        /// Set while a user edit is pushed into the binding, so `updateNSView` does not echo it back.
        private(set) var isEditing = false
        /// Set while the binding's value is applied to the view, so `textDidChange` does not echo it back.
        var isApplyingBinding = false
        private var revision = 0
        private var highlightTask: Task<Void, Never>?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isApplyingBinding else { return }
            isEditing = true
            text.wrappedValue = textView.string
            isEditing = false
            scheduleHighlight(immediately: false)
        }

        /// Recomputes the token spans in the background and applies them if the text has not changed meanwhile.
        func scheduleHighlight(immediately: Bool) {
            revision &+= 1
            let token = revision
            highlightTask?.cancel()
            guard let textView else { return }
            let snapshot = textView.string
            highlightTask = Task { [weak self] in
                if !immediately {
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                }
                let spans = await Task.detached(priority: .utility) {
                    SyntaxHighlighter.spans(in: snapshot, language: SyntaxHighlighter.Language.detect(snapshot))
                }.value
                guard let self, !Task.isCancelled, token == self.revision else { return }
                self.apply(spans)
            }
        }

        private func apply(_ spans: [SyntaxHighlighter.Span]) {
            guard let storage = textView?.textStorage else { return }
            let length = storage.length
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: length))
            for span in spans where span.range.location >= 0 && NSMaxRange(span.range) <= length {
                storage.addAttribute(.foregroundColor, value: CodeEditor.color(for: span.kind), range: span.range)
            }
            storage.endEditing()
        }
    }

    static func color(for kind: SyntaxHighlighter.Kind) -> NSColor {
        switch kind {
        case .key: .adaptive(light: .hex(0x0E7490), dark: .hex(0x67E8F9))
        case .string: .adaptive(light: .hex(0xB45309), dark: .hex(0xFCD34D))
        case .number: .adaptive(light: .hex(0x6D28D9), dark: .hex(0xC4B5FD))
        case .keyword: .adaptive(light: .hex(0xBE185D), dark: .hex(0xF9A8D4))
        case .tag: .adaptive(light: .hex(0x1D4ED8), dark: .hex(0x93C5FD))
        case .attribute: .adaptive(light: .hex(0x0F766E), dark: .hex(0x5EEAD4))
        case .comment: .secondaryLabelColor
        case .cdata: .adaptive(light: .hex(0x4D7C0F), dark: .hex(0xBEF264))
        }
    }
}
