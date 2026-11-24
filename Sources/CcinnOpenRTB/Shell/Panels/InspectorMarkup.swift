import RTBKit
import SwiftUI

/// The Inspector's Markup: the selected bid's markup as the DSP sent it and, when the exchange's macros changed it, as
/// the device receives it — formatted (pure part).
enum InspectorMarkup {
    struct Source: Equatable, Identifiable, Sendable {
        var title: String
        var text: String
        /// What the text is, for the formatter; `nil` for a URL.
        var language: MarkupFormatter.Language?

        var id: String { title }
    }

    /// "In the bid", then "On the device" when the substituted macros changed it; a tag URL or an image banner as one
    /// source; none when the markup is not in the bid (`unavailableReason`).
    static func sources(candidate: AdCandidate, deviceMarkup: AdMarkup?) -> [Source] {
        switch candidate.markup {
        case let .vast(.url(url)):
            return [Source(title: "VAST tag URL", text: url, language: nil)]
        case let .image(banner):
            return [Source(title: "Image banner", text: [banner.imageURL, banner.link?.url].compactMap { $0 }.joined(separator: "\n"), language: nil)]
        case .none:
            return []
        case .html, .native, .vast(.xml):
            guard let bid = text(of: candidate.markup) else { return [] }
            var sources = [Source(title: "In the bid", text: bid.text, language: bid.language)]
            if let deviceMarkup, let device = text(of: deviceMarkup), device.text != bid.text {
                sources.append(Source(title: "On the device", text: device.text, language: device.language))
            }
            return sources
        }
    }

    static func unavailableReason(_ candidate: AdCandidate) -> String? {
        guard case .none = candidate.markup else { return nil }
        return candidate.markupURL != nil
            ? "By reference (display.curl): fetched when the ad renders."
            : "Delivered by the win notice (nurl): Real mode fetches it."
    }

    private static func text(of markup: AdMarkup) -> (text: String, language: MarkupFormatter.Language)? {
        switch markup {
        case let .html(html): (html, .html)
        case let .native(json): (json, .json)
        case let .vast(.xml(xml)): (xml, .vast)
        case .vast(.url), .image, .none: nil
        }
    }
}

/// The selected bid's markup, formatted off the main actor (or as received), read-only, with Copy.
struct InspectorMarkupView: View {
    let candidate: AdCandidate
    let deviceMarkup: AdMarkup?
    @State private var sourceTitle = "In the bid"
    @AppStorage("inspector.markup.formatted") private var formatted = true
    @State private var shown: Shown?

    private struct Shown: Equatable {
        var key: Key
        var text: String
        var summary: String
    }

    private struct Key: Equatable {
        var source: InspectorMarkup.Source
        var formatted: Bool
    }

    var body: some View {
        let sources = InspectorMarkup.sources(candidate: candidate, deviceMarkup: deviceMarkup)
        if let first = sources.first {
            let source = sources.first { $0.title == sourceTitle } ?? first
            content(sources: sources, source: source)
                .task(id: Key(source: source, formatted: formatted)) { await show(Key(source: source, formatted: formatted)) }
        } else {
            ContentUnavailableView("No Markup in the Bid", systemImage: "doc",
                                   description: Text(InspectorMarkup.unavailableReason(candidate) ?? ""))
        }
    }

    private func content(sources: [InspectorMarkup.Source], source: InspectorMarkup.Source) -> some View {
        let current = shown.flatMap { $0.key.source == source ? $0 : nil }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if sources.count > 1 {
                    Picker("Markup", selection: $sourceTitle) {
                        ForEach(sources) { Text($0.title).tag($0.title) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("The markup in the bid, or as the device receives it with the exchange's macros substituted")
                }
                if source.language != nil {
                    Toggle("Formatted", isOn: $formatted)
                        .toggleStyle(.checkbox)
                        .help("Pretty-printed, unescaped when it was copied out of a JSON string; off: as received")
                }
                Spacer(minLength: 0)
                Text(current?.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(current?.summary ?? "")
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(current?.text ?? source.text) }
                    .help("Copy the markup as shown")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            CodeEditor(text: .constant(current?.text ?? source.text), accessibilityLabel: "\(source.title) markup", isEditable: false)
        }
    }

    private func show(_ key: Key) async {
        let source = key.source
        let size = InspectorTree.byteCount(source.text)
        guard key.formatted, let language = source.language else {
            shown = Shown(key: key, text: source.text, summary: (source.language == nil ? "" : "As received · ") + size)
            return
        }
        let result = await Task.detached(priority: .userInitiated) { MarkupFormatter.format(source.text, as: language) }.value
        switch result {
        case let .success(formatted):
            shown = Shown(key: key, text: formatted.text, summary: formatted.summary + " · " + size)
        case let .failure(failure):
            shown = Shown(key: key, text: source.text, summary: failure.message + " · " + size)
        }
    }
}
