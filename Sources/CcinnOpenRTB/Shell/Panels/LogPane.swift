import RTBKit
import SwiftUI

/// The session's lifecycle log (what fired, what was refused and why) and the renderer console.
struct LogPane: View {
    enum Source: String, CaseIterable, Identifiable {
        case lifecycle = "Lifecycle"
        case console = "Renderer console"
        var id: String { rawValue }
    }

    let session: AdSession
    @State private var source: Source = .lifecycle

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Log", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Clear") {
                    switch source {
                    case .lifecycle: session.clearLifecycleLog()
                    case .console: session.clearConsole()
                    }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch source {
            case .lifecycle: LifecycleLogList(entries: session.lifecycleLog)
            case .console: ConsoleList(lines: session.console)
            }
        }
    }
}

private struct LifecycleLogList: View {
    let entries: [LifecycleLogEntry]

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No Events Yet", systemImage: "list.bullet.rectangle",
                                   description: Text("Render a bid: every lifecycle event and what it fired appears here."))
        } else {
            ScrollViewReader { proxy in
                List(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.time, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                            .font(Theme.monospacedSmall)
                            .foregroundStyle(.tertiary)
                        Text(entry.origin)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(entry.label).lineLimit(1)
                        Spacer(minLength: 4)
                        outcome(entry.outcome)
                    }
                    .id(entry.id)
                }
                .listStyle(.plain)
                .onChange(of: entries.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder private func outcome(_ outcome: LifecycleLogEntry.Outcome) -> some View {
        switch outcome {
        case let .fired(requests):
            Text(requests == 0 ? "—" : "\(requests) request\(requests == 1 ? "" : "s")").font(.caption).foregroundStyle(.green)
        case .alreadyFired:
            Text("already fired").font(.caption).foregroundStyle(.orange)
        case .contradictsOutcome:
            Text("contradicts win/loss").font(.caption).foregroundStyle(.red)
        case let .ignored(reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ConsoleList: View {
    let lines: [ConsoleLine]

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView("Console Is Empty", systemImage: "terminal",
                                   description: Text("MRAID bridge calls, player and Native renderer messages appear here."))
        } else {
            List(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: line.entry.level)).foregroundStyle(color(for: line.entry.level)).font(.caption)
                    Text(line.entry.origin).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    Text(line.entry.message).font(Theme.monospacedSmall).textSelection(.enabled)
                }
            }
            .listStyle(.plain)
        }
    }

    private func symbol(for level: RendererLogEntry.Level) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func color(for level: RendererLogEntry.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
