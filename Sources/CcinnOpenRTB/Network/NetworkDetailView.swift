import AppKit
import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// Everything about one request: summary, template vs expanded URL with macros, query, headers, redirects, related
/// requests and a response preview.
struct NetworkDetailView: View {
    let entry: NetworkEntry
    let entries: [NetworkEntry]
    let origin: Date?
    let monitor: NetworkMonitor
    let select: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summary
                urlSection
                let query = URLText.queryItems(entry.url)
                if !query.isEmpty {
                    section("Query Parameters") { KeyValueGrid(rows: query.map { ($0.name, $0.value) }) }
                }
                redirectSection
                relatedSection
                if !entry.requestHeaders.isEmpty {
                    section(NetworkPresentation.requestHeadersTitle(for: entry)) {
                        KeyValueGrid(rows: HTTPHeaders.sorted(entry.requestHeaders).map { ($0.name, $0.value) })
                    }
                }
                if !entry.responseHeaders.isEmpty {
                    section("Response Headers") { KeyValueGrid(rows: HTTPHeaders.sorted(entry.responseHeaders).map { ($0.name, $0.value) }) }
                }
                previewSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RequestCategoryBadge(entry: entry)
                DeliveryBadge(delivery: entry.delivery)
                if entry.isScript { Badge(text: "Script", color: .secondary, systemImage: "curlybraces") }
                Spacer()
                Text(Theme.statusText(for: entry)).font(.headline.monospacedDigit()).foregroundStyle(Theme.color(for: entry.state))
            }
            Text(entry.trigger).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(entry.source).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Copy URL", systemImage: "link") { Pasteboard.copy(entry.url) }
                Button("Copy as curl", systemImage: "terminal") { Pasteboard.copy(CurlCommand.make(for: entry)) }
            }
            .controlSize(.small)
            if let message = NetworkCells.failureMessage(entry) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var summary: some View {
        var rows: [(String, String)] = [("Sequence", "#\(entry.sequence)")]
        if let origin {
            rows.append(("Started", "\(Format.offset(entry.startedAt.timeIntervalSince(origin))) ms · "
                + entry.startedAt.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))))
        }
        rows.append(("Duration", entry.state == .pending ? "pending" : Format.duration(seconds: entry.duration)))
        rows.append(("Mode", "\(entry.delivery.label) · session \(entry.sessionMode == .real ? "Real" : "Simulated")"))
        rows.append(("Method", entry.method))
        if let bytes = entry.responseBytes { rows.append(("Size", Format.bytes(bytes))) }
        if let mime = entry.mimeType { rows.append(("Type", mime)) }
        if let timings = entry.timings {
            let parts = [("DNS", timings.dns), ("connect", timings.connect), ("TLS", timings.ssl), ("wait", timings.wait), ("receive", timings.receive)]
                .compactMap { name, value in value.map { "\(name) \(Format.duration(milliseconds: $0))" } }
            rows.append(("Timing", parts.joined(separator: " · ")))
        }
        if let note = entry.note { rows.append(("Note", note)) }
        return section("Summary") { KeyValueGrid(rows: rows, monospaced: false) }
    }

    private var urlSection: some View {
        section("URL") {
            VStack(alignment: .leading, spacing: 10) {
                if entry.template != entry.url {
                    labeled("Template") { Text(MacroHighlighter.template(entry)).font(Theme.monospacedSmall).textSelection(.enabled) }
                }
                if entry.template != entry.url {
                    labeled("Expanded") { Text(MacroHighlighter.expanded(entry)).font(Theme.monospacedSmall).textSelection(.enabled) }
                } else {
                    Text(MacroHighlighter.expanded(entry)).font(Theme.monospacedSmall).textSelection(.enabled)
                }
                if !entry.replacedMacros.isEmpty || !entry.unknownMacros.isEmpty {
                    FlowChips(replaced: entry.replacedMacros, unknown: entry.unknownMacros)
                }
            }
        }
    }

    @ViewBuilder
    private var redirectSection: some View {
        let rootID = entry.isRedirectHop ? (entry.parentID ?? entry.id) : entry.id
        let hops = entries.filter { $0.parentID == rootID && $0.isRedirectHop }
        if !hops.isEmpty, let root = entries.first(where: { $0.id == rootID }) {
            section("Redirect Chain") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([root] + hops) { hop in
                        RelatedRow(entry: hop, current: hop.id == entry.id, label: hop.redirectLocation == nil ? "request" : "Location") { select(hop.id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        let parent = entry.parentID.flatMap { id in entries.first { $0.id == id } }
        let children = entries.filter { $0.parentID == entry.id && !$0.isRedirectHop }
        if parent != nil || !children.isEmpty {
            section("Related") {
                VStack(alignment: .leading, spacing: 4) {
                    if let parent, !entry.isRedirectHop {
                        RelatedRow(entry: parent, current: false, label: "parent") { select(parent.id) }
                    }
                    ForEach(children.prefix(200)) { child in
                        RelatedRow(entry: child, current: false, label: "child") { select(child.id) }
                    }
                    if children.count > 200 {
                        Text("…and \(children.count - 200) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let body = monitor.responseBody(for: entry.id), !body.isEmpty {
            section("Response Preview") {
                ResponsePreview(data: body, mimeType: entry.mimeType, contentType: entry.responseHeader("Content-Type"))
            }
        } else if let bytes = entry.responseBytes, bytes > 0 {
            section("Response") {
                Text("\(Format.bytes(bytes)) of \(entry.mimeType ?? "data") (not kept for preview)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Building blocks

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Macro highlighting: in the template, replaced macros are green and unknown ones orange; in the expanded URL,
/// whatever macros are still present (unknown, left in place) are orange.
enum MacroHighlighter {
    static func template(_ entry: NetworkEntry) -> AttributedString {
        highlight(entry.template) { token in
            if entry.unknownMacros.contains(token) { return .macroUnknown }
            return entry.replacedMacros.contains(token) ? .macroReplaced : .appAccent
        }
    }

    static func expanded(_ entry: NetworkEntry) -> AttributedString {
        highlight(entry.url) { _ in .macroUnknown }
    }

    static func highlight(_ text: String, color: (String) -> NSColor) -> AttributedString {
        let limited = text.count > 20_000 ? String(text.prefix(20_000)) + "…" : text
        var attributed = AttributedString(limited)
        for token in MacroTokens.find(in: limited) {
            guard let range = Range(token.range, in: attributed) else { continue }
            attributed[range].foregroundColor = Color(nsColor: color(token.text))
            attributed[range].font = Theme.monospacedSmall.weight(.bold)
        }
        return attributed
    }
}

private struct FlowChips: View {
    let replaced: [String]
    let unknown: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !replaced.isEmpty {
                chips("Replaced", replaced, color: Color(nsColor: .macroReplaced), icon: "checkmark.circle")
            }
            if !unknown.isEmpty {
                chips("Unknown", unknown, color: Color(nsColor: .macroUnknown), icon: "questionmark.circle")
            }
        }
    }

    private func chips(_ title: String, _ macros: [String], color: Color, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { ForEach(macros, id: \.self) { Badge(text: $0, color: color, systemImage: icon) } }
                Text(macros.joined(separator: "  ")).font(Theme.monospacedSmall).foregroundStyle(color).textSelection(.enabled)
            }
        }
    }
}

private struct RelatedRow: View {
    let entry: NetworkEntry
    let current: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("#\(entry.sequence)").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Text(Theme.statusText(for: entry)).monospacedDigit().foregroundStyle(Theme.color(for: entry.state)).frame(width: 52, alignment: .leading)
                Text(entry.redirectLocation ?? URLText.hostAndPath(entry.url)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(label).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(current ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.url)
    }
}

/// Name/value rows (headers, query parameters, summary).
struct KeyValueGrid: View {
    let rows: [(String, String)]
    var monospaced = true

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(row.1).font(monospaced ? Theme.monospacedSmall : .callout).textSelection(.enabled).lineLimit(8)
                }
            }
        }
        .font(.callout)
    }
}

/// Text (XML, JSON, HTML, …), image or a size line.
private struct ResponsePreview: View {
    let data: Data
    let mimeType: String?
    let contentType: String?

    static let maxCharacters = 64 * 1024

    var body: some View {
        let mime = mimeType?.lowercased() ?? ""
        if mime.hasPrefix("image/"), let image = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 360), maxHeight: 240, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                Text("\(Int(image.size.width))×\(Int(image.size.height)) · \(Format.bytes(data.count))").font(.caption).foregroundStyle(.secondary)
            }
        } else if TextDecoding.isTextual(mimeType: mime) || mime.isEmpty || looksLikeText {
            let text = TextDecoding.string(from: data, charset: HTTPHeaders.charset(fromContentType: contentType))
            let shown = text.count > Self.maxCharacters ? String(text.prefix(Self.maxCharacters)) + "\n…" : text
            ScrollView(.horizontal) {
                Text(shown)
                    .font(Theme.monospacedSmall)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .frame(maxHeight: 360)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text("\(Format.bytes(data.count)) of \(mimeType ?? "binary data")").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var looksLikeText: Bool {
        data.prefix(512).allSatisfy { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || ($0 >= 0x20 && $0 != 0x7F) }
    }
}
