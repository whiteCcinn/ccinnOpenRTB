import RTBKit
import SwiftUI

/// The right half of the main window: the Client (send a bid request), the response and request editors, the Inspector,
/// the Macros and the event log, with the bid picker and the status line.
struct InputPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case client = "Client"
        case sync = "Sync"
        case response = "Response"
        case request = "Request"
        case inspector = "Inspector"
        case macros = "Macros"
        case log = "Log"

        var id: String { rawValue }
    }

    @Bindable var session: AdSession
    let client: ClientModel
    let sync: SyncModel
    @SceneStorage("inputPanel.tab") private var tab: Tab = .response

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Panel", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            BidPickerBar(session: session)
            Divider()
            Group {
                switch tab {
                case .client: ClientPane(client: client, session: session)
                case .sync: SyncPane(sync: sync)
                case .response: ResponsePane(session: session)
                case .request: RequestPane(session: session)
                case .inspector: InspectorPane(session: session)
                case .macros: MacrosPane(session: session)
                case .log: LogPane(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusLine(session: session)
        }
    }
}

// MARK: - Bid picker

/// Which bid of the response the simulator renders.
private struct BidPickerBar: View {
    @Bindable var session: AdSession

    var body: some View {
        let candidates = session.parsed.candidates
        HStack(spacing: 8) {
            Image(systemName: "list.number").foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text(session.parsed.noBidReason.map { "No bid · nbr \($0) · \(NoBidReason.title(for: $0))" } ?? "No bids in the input")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Picker("Bid", selection: $session.selectedCandidateID) {
                    ForEach(candidates) { candidate in
                        Text(InputSummary.title(of: candidate)).tag(Optional(candidate.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .help("The bid the simulator renders (\(candidates.count) in the response)")
                if session.renderIsStale {
                    Button("Render") { session.render() }
                        .help("The device shows another bid: render this one")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Status line

private struct StatusLine: View {
    let session: AdSession

    var body: some View {
        let issues = session.issues
        let severity = InputSummary.worstSeverity(issues)
        HStack(spacing: 6) {
            Circle()
                .fill(color(for: severity))
                .frame(width: 7, height: 7)
            Text(InputSummary.status(of: session.parsed, issues: issues, isParsing: session.isParsing))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(InspectorTree.byteCount(session.responseText))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private func color(for severity: ValidationIssue.Severity?) -> Color {
        switch severity {
        case .error?: .red
        case .warning?: .orange
        case .info?: .blue
        case nil: session.parsed.candidates.isEmpty ? .secondary : .green
        }
    }
}

// MARK: - Response and request

private struct ResponsePane: View {
    @Bindable var session: AdSession
    @State private var formatError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SampleMenu(session: session)
                Button {
                    format()
                } label: {
                    Label("Format", systemImage: "text.alignleft")
                }
                .help("Pretty-print the JSON (keeps key order and number spelling) (⇧⌘F)")
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(SyntaxHighlighter.Language.detect(session.responseText) != .json)
                Button {
                    session.responseText = ""
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .disabled(session.responseText.isEmpty)
                Spacer(minLength: 0)
                if let formatError {
                    Text(formatError).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            VSplitView {
                EditorWithPlaceholder(text: $session.responseText, placeholder: Self.placeholder, label: "Bid response")
                    .frame(minHeight: 160, maxHeight: .infinity)
                if !session.issues.isEmpty {
                    IssuesList(issues: session.issues)
                        .frame(minHeight: 80, idealHeight: 150, maxHeight: 320)
                }
            }
        }
    }

    private static let placeholder = """
    Paste an OpenRTB 2.x / 3.0 bid response, Native JSON, VAST XML, a VAST tag URL or HTML markup — or pick a sample.
    """

    private func format() {
        let text = session.responseText
        Task {
            let formatted = await Task.detached(priority: .userInitiated) { JSONFormatter.prettyPrinted(text) }.value
            guard session.responseText == text else { return }
            if let formatted {
                formatError = nil
                session.responseText = formatted
            } else {
                formatError = "Not well-formed JSON: unbalanced brackets or an open string"
            }
        }
    }
}

private struct RequestPane: View {
    @Bindable var session: AdSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Optional. Resolves Native asset types, impression sizes and media types, and the auction macros.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Clear") { session.requestText = "" }
                    .controlSize(.small)
                    .disabled(session.requestText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            EditorWithPlaceholder(text: $session.requestText, placeholder: "Paste the OpenRTB bid request (optional).", label: "Bid request")
        }
    }
}

private struct EditorWithPlaceholder: View {
    @Binding var text: String
    let placeholder: String
    let label: String

    var body: some View {
        CodeEditor(text: $text, accessibilityLabel: label)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Built-in samples, grouped (SampleLibrary).
struct SampleMenu: View {
    let session: AdSession

    var body: some View {
        let samples = session.services.samples()
        let groups = Dictionary(grouping: samples, by: \.group)
        let order = samples.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        Menu {
            if samples.isEmpty {
                Text("No samples available")
            }
            ForEach(order, id: \.self) { group in
                Section(group) {
                    ForEach(groups[group] ?? []) { sample in
                        Button(sample.title) { Task { await session.load(sample) } }
                    }
                }
            }
        } label: {
            Label("Samples", systemImage: "tray.full")
        }
        .fixedSize()
        .help("Load a built-in sample and render it")
    }
}

// MARK: - Issues

struct IssuesList: View {
    let issues: [ValidationIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Issues").font(.caption.weight(.semibold))
                Text("\(issues.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            List(Array(issues.enumerated()), id: \.offset) { _, issue in
                IssueRow(issue: issue)
            }
            .listStyle(.plain)
        }
    }
}

struct IssueRow: View {
    let issue: ValidationIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(for: issue.severity))
                .foregroundStyle(Self.color(for: issue.severity))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(issue.code).font(Theme.monospacedSmall).foregroundStyle(.secondary)
                    Text(issue.path).font(Theme.monospacedSmall).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Path") { Pasteboard.copy(issue.path) }
            Button("Copy Code") { Pasteboard.copy(issue.code) }
            Button("Copy Message") { Pasteboard.copy(issue.message) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(issue.severity.rawValue): \(issue.message), \(issue.path)")
    }

    static func symbol(for severity: ValidationIssue.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    static func color(for severity: ValidationIssue.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}
