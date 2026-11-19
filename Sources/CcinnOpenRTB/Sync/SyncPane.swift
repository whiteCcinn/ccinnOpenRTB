import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// The Sync tab: run a cookie-sync chain as the device's browser would, and see every hop's cookies, the ids passed
/// along and what broke the match. Small views, so each builder type-checks quickly (CI runs Swift 6.2).
struct SyncPane: View {
    @Bindable var sync: SyncModel

    var body: some View {
        VStack(spacing: 0) {
            SyncStartBar(sync: sync)
            SyncSettingsBar(sync: sync)
            SyncConsentSection(sync: sync)
            if let note = sync.jarNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if let problem = sync.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            Divider()
            SyncResultView(sync: sync)
        }
    }
}

private struct SyncStartBar: View {
    @Bindable var sync: SyncModel

    var body: some View {
        HStack(spacing: 8) {
            TextField("Start URL", text: $sync.startURL,
                      prompt: Text("https://ssp.example/usersync?gdpr=${GDPR}&gdpr_consent=${GDPR_CONSENT_755}"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { sync.run() }
                .accessibilityLabel("Sync start URL")
            if sync.isRunning {
                Button("Cancel", systemImage: "xmark", role: .cancel) { sync.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    sync.run()
                } label: {
                    Label(sync.runCount == 0 ? "Run" : "Run Again", systemImage: "arrow.triangle.2.circlepath")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Run the sync chain on the page, as the browser would, with the cookie jar (⌘↩)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The page the sync runs on, and the browser's third-party cookie policy.
private struct SyncSettingsBar: View {
    @Bindable var sync: SyncModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Page").foregroundStyle(.secondary)
            TextField("Publisher page", text: $sync.publisherURL, prompt: Text("https://news.example/"))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
                .help("The page the sync pixel is on: its site decides which cookies are third party, and its origin is the Referer")
            Picker("Browser", selection: $sync.browser) {
                ForEach(SyncBrowser.allCases) { browser in
                    Text(browser.title).tag(browser)
                }
            }
            .fixedSize()
            .help(sync.browser.detail + (sync.browserOverride == nil ? " — the \(sync.device.name)’s browser" : " — chosen by hand")
                + ". Its User-Agent goes with the requests.")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// Consent values the IAB URL macros (`${GDPR}`, `${GDPR_CONSENT_<id>}`, `${US_PRIVACY}`, `${GPP_STRING_<id>}`,
/// `${GPP_SID}`) are filled with.
private struct SyncConsentSection: View {
    @Bindable var sync: SyncModel

    private var gdpr: Binding<Int> {
        Binding(get: { sync.consent.gdprApplies.map { $0 ? 1 : 0 } ?? -1 },
                set: { sync.consent.gdprApplies = $0 < 0 ? nil : $0 == 1 })
    }

    private func text(_ keyPath: WritableKeyPath<SyncConsent, String?>) -> Binding<String> {
        Binding(get: { sync.consent[keyPath: keyPath] ?? "" }, set: { sync.consent[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private var sectionIDs: Binding<String> {
        Binding(get: { sync.consent.gppSectionIDs.map(String.init).joined(separator: ",") },
                set: { sync.consent.gppSectionIDs = $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } })
    }

    var body: some View {
        DisclosureGroup("Consent macros") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("${GDPR}").foregroundStyle(.secondary)
                    Picker("GDPR", selection: gdpr) {
                        Text("Unknown (empty)").tag(-1)
                        Text("Applies (1)").tag(1)
                        Text("Does not apply (0)").tag(0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("${GDPR_CONSENT_…}").foregroundStyle(.secondary)
                    TextField("TC string", text: text(\.tcString))
                }
                GridRow {
                    Text("${US_PRIVACY}").foregroundStyle(.secondary)
                    TextField("1YNN", text: text(\.usPrivacy))
                }
                GridRow {
                    Text("${GPP_STRING_…}").foregroundStyle(.secondary)
                    TextField("GPP string", text: text(\.gppString))
                }
                GridRow {
                    Text("${GPP_SID}").foregroundStyle(.secondary)
                    TextField("2,6", text: sectionIDs)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
            .padding(.top, 4)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

// MARK: - Result

private struct SyncResultView: View {
    enum Tab: Hashable { case run, jar }

    let sync: SyncModel
    @State private var tab: Tab = .run

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Result", selection: $tab) {
                    Text("Run").tag(Tab.run)
                    Text("Cookie Jar (\(sync.session.jar.cookies.count))").tag(Tab.jar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Button("Clear Cookies", systemImage: "trash") { sync.clearCookies() }
                    .disabled(sync.session.jar.cookies.isEmpty)
                    .help("Empty this window’s cookie jar (never the Mac’s cookies)")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .run:
                if let run = sync.lastRun {
                    SyncRunView(run: run)
                } else if sync.isRunning {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Run Yet", systemImage: "link",
                                           description: Text("Enter the SSP’s sync endpoint (or a partner’s pixel) and Run: every redirect is followed with this window’s cookie jar, as the browser would."))
                }
            case .jar:
                SyncJarView(cookies: sync.session.jar.cookies)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SyncRunView: View {
    let run: SyncRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(SyncPresentation.verdicts(for: run).enumerated()), id: \.offset) { _, verdict in
                        Label(verdict, systemImage: Self.symbol(for: verdict))
                            .foregroundStyle(Self.color(for: verdict))
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
                Text("\(run.browser.title) (\(SyncPresentation.title(for: run.browser.policy).lowercased())) · page \(run.topLevelSite.description) · \(run.ranAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(run.chain.enumerated()), id: \.offset) { index, hop in
                    SyncHopRow(index: index, hop: hop, leftovers: run.leftovers.filter { $0.hopIndex == index }.map(\.placeholder), ranAt: run.ranAt)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func symbol(for verdict: String) -> String {
        verdict.hasPrefix("Mapped") ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private static func color(for verdict: String) -> Color {
        verdict.hasPrefix("Mapped") ? .green : .orange
    }
}

private struct SyncHopRow: View {
    let index: Int
    let hop: ComposedHop
    let leftovers: [String]
    let ranAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                if let status = hop.status {
                    Badge(text: ClientPresentation.statusText(status), color: ClientPresentation.statusTone(status).color)
                } else {
                    Badge(text: hop.wasSent ? "failed" : "not sent", color: .orange)
                }
                Text(URLText.host(hop.url) ?? "").fontWeight(.semibold)
            }
            Text(hop.url).font(Theme.monospacedSmall).textSelection(.enabled).lineLimit(4).padding(.leading, 24)
            if let location = hop.location {
                Label(location, systemImage: "arrow.turn.down.right").font(Theme.monospacedSmall).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(4).padding(.leading, 24)
            }
            ForEach(leftovers, id: \.self) { placeholder in
                Label("\(placeholder) not substituted", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(.leading, 24)
            }
            if let cookies = hop.cookies { SyncCookieLines(cookies: cookies, ranAt: ranAt).padding(.leading, 24) }
            if let failure = hop.failure { Text(failure).foregroundStyle(.orange).padding(.leading, 24) }
        }
        .font(.caption)
    }
}

/// Sent, withheld (why), stored and rejected (why).
private struct SyncCookieLines: View {
    let cookies: NetworkCookies
    let ranAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !cookies.sent.isEmpty {
                line("arrow.up.circle", .secondary, "Sent: " + cookies.sent.map { "\($0.name)=\($0.value.prefix(40))" }.joined(separator: "; "))
            }
            ForEach(Array(cookies.withheld.enumerated()), id: \.offset) { _, withheld in
                line("minus.circle", .orange, "\(withheld.cookie.name): \(SyncPresentation.explain(withheld.reason))")
            }
            ForEach(Array(cookies.decisions.enumerated()), id: \.offset) { _, decision in
                switch decision {
                case let .stored(cookie), let .replaced(cookie):
                    line("arrow.down.circle.fill", .green, "Stored " + SyncPresentation.describe(cookie, now: ranAt))
                case let .deleted(name):
                    line("trash.circle", .secondary, "Deleted \(name)")
                case let .expiredOnArrival(name):
                    line("clock.badge.xmark", .secondary, "\(name): expired on arrival, nothing to delete")
                case let .rejected(name, reason):
                    line("xmark.circle.fill", .red, "Rejected \(name.isEmpty ? "a cookie" : name): \(SyncPresentation.explain(reason))")
                }
            }
        }
    }

    private func line(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(color).textSelection(.enabled).lineLimit(3)
    }
}

private struct SyncJarView: View {
    let cookies: [StoredCookie]

    var body: some View {
        if cookies.isEmpty {
            ContentUnavailableView("Empty Jar", systemImage: "tray",
                                   description: Text("Cookies the sync chain stores appear here. They live in this window only, never in the Mac’s browser."))
        } else {
            let byDomain = Dictionary(grouping: cookies, by: \.domain)
            List {
                ForEach(byDomain.keys.sorted(), id: \.self) { domain in
                    Section(domain) {
                        ForEach(byDomain[domain] ?? []) { cookie in
                            Text(SyncPresentation.describe(cookie, now: Date()))
                                .font(Theme.monospacedSmall)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
