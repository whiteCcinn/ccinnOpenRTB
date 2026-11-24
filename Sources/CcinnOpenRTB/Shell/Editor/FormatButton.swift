import SwiftUI

/// What the last Format did ("Unescaped a JSON string · VAST XML") or why it did nothing, for the text it left.
struct FormatNote: Equatable {
    var text: String
    var message: String
    var isProblem: Bool
}

/// Format (⇧⌘F) for an editor: unescapes text copied out of a JSON string, then pretty-prints JSON, VAST / XML or HTML
/// off the main actor (`MarkupFormatter`). An edit made meanwhile wins. Undoable in the editor.
struct FormatButton: View {
    @Binding var text: String
    @Binding var note: FormatNote?

    var body: some View {
        Button {
            format()
        } label: {
            Label("Format", systemImage: "text.alignleft")
        }
        .help("Pretty-print JSON, VAST XML or HTML without changing what it means; text copied out of a JSON string is unescaped first (⇧⌘F)")
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(!MarkupFormatter.mightFormat(text))
    }

    private func format() {
        let original = text
        Task {
            let result = await Task.detached(priority: .userInitiated) { MarkupFormatter.format(original) }.value
            guard text == original else { return }
            switch result {
            case let .success(formatted):
                text = formatted.text
                note = FormatNote(text: formatted.text, message: formatted.summary, isProblem: formatted.problem != nil)
            case let .failure(failure):
                note = FormatNote(text: original, message: failure.message, isProblem: true)
            }
        }
    }
}

/// The note of the last Format, while the editor still holds the text it applies to.
struct FormatNoteLabel: View {
    let note: FormatNote?
    let text: String

    var body: some View {
        if let note, note.text == text {
            Text(note.message)
                .font(.caption)
                .foregroundStyle(note.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(note.message)
        }
    }
}
