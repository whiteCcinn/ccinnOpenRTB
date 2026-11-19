import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// The Prebid tab: official Prebid.js on a simulated publisher page — version, bidders and params, consent — an auction
/// through the window's network gate, and its bids on the device. Small views (CI type-checks with Swift 6.2).
struct PrebidPane: View {
    @Bindable var prebid: PrebidModel
    /// Shows the Sync tab (after a sync was handed to it).
    let openSyncTab: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PrebidRunBar(prebid: prebid)
            PrebidStatusLine(prebid: prebid)
            Divider()
            VSplitView {
                PrebidSetupView(prebid: prebid)
                    .frame(minHeight: 160, idealHeight: 300, maxHeight: .infinity)
                PrebidResultsView(prebid: prebid, openSyncTab: openSyncTab)
                    .frame(minHeight: 140, idealHeight: 260, maxHeight: .infinity)
            }
        }
        .onAppear { prebid.start() }
    }
}

private struct PrebidRunBar: View {
    @Bindable var prebid: PrebidModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("Prebid.js", selection: Binding(get: { prebid.setup.version }, set: { prebid.choose(version: $0) })) {
                if prebid.versions.isEmpty { Text(prebid.setup.version.isEmpty ? "Loading…" : prebid.setup.version).tag(prebid.setup.version) }
                ForEach(prebid.versions.prefix(60), id: \.self) { version in
                    Text(version == prebid.defaultVersion ? "\(version) (default)" : version).tag(version)
                }
            }
            .fixedSize()
            .help("The default is the newest Prebid.js release at least two weeks old")
            TextField("Page", text: $prebid.setup.pageURL, prompt: Text("https://news.example/article"))
                .textFieldStyle(.roundedBorder)
                .help("The page the bidders see (Prebid's pageUrl); its host is the page's origin")
            Stepper("\(prebid.setup.timeoutMilliseconds) ms", value: $prebid.setup.timeoutMilliseconds, in: 200...10_000, step: 100)
                .fixedSize()
                .help("Bidder timeout")
            if prebid.phase == .running {
                Button("Stop", systemImage: "stop.fill") { prebid.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    prebid.runAuction()
                } label: {
                    Label("Run Auction", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(prebid.catalog.isEmpty || prebid.phase == .preparing)
                .help("Load the page and run pbjs.requestBids: every bidder request goes through this window’s network (⌘↩)")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct PrebidStatusLine: View {
    let prebid: PrebidModel

    var body: some View {
        let problems = prebid.catalog.isEmpty ? [] : prebid.setup.problems(catalog: prebid.catalog).map(\.message)
        VStack(alignment: .leading, spacing: 2) {
            switch prebid.phase {
            case .preparing: Label("Loading Prebid.js \(prebid.setup.version)…", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
            case let .failed(message):
                HStack(spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if prebid.versions.isEmpty || prebid.catalog.isEmpty {
                        Button("Retry") { prebid.start() }.controlSize(.mini)
                    }
                }
            case .running: Label("Auction running…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .done: Label("\(prebid.bids.count) bid(s) · Prebid.js \(prebid.loadedVersion ?? prebid.setup.version)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            case .idle: EmptyView()
            }
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - Setup

private struct PrebidSetupView: View {
    @Bindable var prebid: PrebidModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($prebid.setup.adUnits) { $unit in
                    PrebidAdUnitEditor(unit: $unit, catalog: prebid.catalog) {
                        prebid.setup.adUnits.removeAll { $0.id == unit.id }
                    }
                }
                Button("Add Ad Unit", systemImage: "plus") {
                    prebid.setup.adUnits.append(PrebidAdUnit(code: "div-\(prebid.setup.adUnits.count + 1)", mediaType: .banner,
                                                             sizes: [AdSize(width: 300, height: 250)], bids: []))
                }
                .controlSize(.small)
                PrebidConsentSection(consent: $prebid.setup.consent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PrebidAdUnitEditor: View {
    @Binding var unit: PrebidAdUnit
    let catalog: [String: PrebidBidder]
    let remove: () -> Void
    @State private var addsBidder = false

    private var sizes: Binding<String> {
        Binding(get: { unit.sizes.map { "\($0.width)x\($0.height)" }.joined(separator: ", ") },
                set: { text in
                    unit.sizes = text.split(separator: ",").compactMap { part in
                        let numbers = part.lowercased().split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                        return numbers.count == 2 && numbers[0] > 0 && numbers[1] > 0 ? AdSize(width: numbers[0], height: numbers[1]) : nil
                    }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Code", text: $unit.code).frame(minWidth: 100, idealWidth: 140, maxWidth: 180)
                Picker("Media", selection: $unit.mediaType) {
                    ForEach(PrebidMediaType.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Sizes", text: sizes, prompt: Text("300x250, 320x50"))
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove the ad unit")
            }
            .textFieldStyle(.roundedBorder)
            ForEach($unit.bids) { $bid in
                PrebidBidderEditor(bid: $bid, known: catalog[bid.bidder]) {
                    unit.bids.removeAll { $0.id == bid.id }
                }
            }
            Button("Add Bidder", systemImage: "plus") { addsBidder = true }
                .controlSize(.small)
                .popover(isPresented: $addsBidder) {
                    PrebidBidderPicker(catalog: catalog) { code in
                        unit.bids.append(PrebidBidderParams(bidder: code))
                        addsBidder = false
                    }
                }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct PrebidBidderEditor: View {
    @Binding var bid: PrebidBidderParams
    let known: PrebidBidder?
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(bid.bidder).font(.callout.weight(.semibold))
                if let alias = known?.aliasOf { Text("alias of \(alias)").font(.caption).foregroundStyle(.secondary) }
                if known == nil { Text("not in this version").font(.caption).foregroundStyle(.red) }
                Spacer(minLength: 0)
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove the bidder")
            }
            TextEditor(text: $bid.params)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 40, maxHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityLabel("\(bid.bidder) params")
        }
        .padding(.leading, 8)
    }
}

/// The version's bidders (aliases included), searchable.
private struct PrebidBidderPicker: View {
    let catalog: [String: PrebidBidder]
    let pick: (String) -> Void
    @State private var query = ""

    var body: some View {
        let codes = catalog.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            TextField("Search \(catalog.count) bidders", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(codes, id: \.self) { code in
                HStack {
                    Text(code)
                    if let alias = catalog[code]?.aliasOf { Text("→ \(alias)").foregroundStyle(.secondary) }
                    Spacer()
                    if let gvlid = catalog[code]?.gvlid { Text("GVL \(gvlid)").font(.caption).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
                .onTapGesture { pick(code) }
            }
            .listStyle(.plain)
        }
        .frame(width: 300, height: 360)
    }
}

private struct PrebidConsentSection: View {
    @Binding var consent: PrebidConsent

    private var gdpr: Binding<Int> {
        Binding(get: { consent.gdprApplies.map { $0 ? 1 : 0 } ?? -1 }, set: { consent.gdprApplies = $0 < 0 ? nil : $0 == 1 })
    }

    var body: some View {
        DisclosureGroup("Consent (static)") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("TCF").foregroundStyle(.secondary)
                    Picker("GDPR", selection: gdpr) {
                        Text("No consent module").tag(-1)
                        Text("GDPR applies").tag(1)
                        Text("GDPR does not apply").tag(0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("TC string").foregroundStyle(.secondary)
                    TextField("TC string", text: $consent.tcString)
                }
                GridRow {
                    Text("US privacy").foregroundStyle(.secondary)
                    TextField("1YNN", text: $consent.usPrivacy)
                }
                GridRow {
                    Text("GPP").foregroundStyle(.secondary)
                    TextField("GPP string", text: $consent.gppString)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            Text("Static values (cmpApi: 'static'): never a CMP lookup, which cancels the auction when the page has no CMP. Under TCF, the bidders' vendors are consented.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

// MARK: - Results

private struct PrebidResultsView: View {
    enum Tab: Hashable { case bids, timeline, syncs, log }

    let prebid: PrebidModel
    let openSyncTab: () -> Void
    @State private var tab: Tab = .bids

    var body: some View {
        VStack(spacing: 0) {
            Picker("Results", selection: $tab) {
                Text("Bids (\(prebid.bids.count))").tag(Tab.bids)
                Text("Timeline").tag(Tab.timeline)
                Text("Syncs (\(prebid.syncs.count))").tag(Tab.syncs)
                Text("Log (\(prebid.warnings.count))").tag(Tab.log)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(6)
            Divider()
            switch tab {
            case .bids: PrebidBidsList(prebid: prebid)
            case .timeline:
                List(prebid.timeline) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("+\(entry.at) ms").monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        Text(entry.type).fontWeight(.semibold)
                        Text(entry.summary).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    .font(.caption)
                }
                .listStyle(.plain)
            case .syncs:
                List(prebid.syncs, id: \.self) { sync in
                    HStack {
                        Badge(text: sync.kind)
                        Text(sync.url).font(Theme.monospacedSmall).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Use in Sync Tab") {
                            prebid.useInSyncTab(sync)
                            openSyncTab()
                        }
                            .controlSize(.small)
                            .help("Put this URL in the Sync tab, to run it with the cookie jar as the browser would")
                    }
                }
                .listStyle(.plain)
            case .log:
                List(Array(prebid.warnings.enumerated()), id: \.offset) { _, line in
                    Text(line).font(Theme.monospacedSmall).foregroundStyle(line.lowercased().contains("invalid") ? .orange : .secondary)
                        .textSelection(.enabled)
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct PrebidBidsList: View {
    let prebid: PrebidModel

    var body: some View {
        if prebid.bids.isEmpty {
            ContentUnavailableView(prebid.phase == .done ? "No Bids" : "No Auction Yet", systemImage: "gavel",
                                   description: Text(prebid.phase == .done ? "See the Timeline for no-bids and timeouts, and the Log for invalid params."
                                       : "Run the auction: the bids appear here, and Render shows one on the device."))
        } else {
            List(Array(prebid.bids.enumerated()), id: \.offset) { _, bid in
                HStack(spacing: 8) {
                    Text(bid.bidderCode).fontWeight(.semibold)
                    Text("\(InputSummary.price(bid.cpm)) \(bid.currency)").monospacedDigit()
                    if let width = bid.width, let height = bid.height { Text("\(width)×\(height)").foregroundStyle(.secondary) }
                    Text(InputSummary.formatTitle(bid.format)).foregroundStyle(.secondary)
                    Text(bid.adUnitCode ?? "").foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    Button("Render") { Task { await prebid.render(bid) } }
                        .controlSize(.small)
                        .help("Show this bid on the device (by the simulator, as an OpenRTB bid of this bidder)")
                }
                .font(.callout)
            }
            .listStyle(.plain)
        }
    }
}
