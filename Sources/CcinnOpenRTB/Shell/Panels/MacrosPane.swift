import RTBKit
import SwiftUI

/// The Macros panel (design D4): values substituted into tracker URLs, and the auction options.
struct MacrosPane: View {
    @Bindable var session: AdSession

    var body: some View {
        Form {
            Section {
                TextField("Clearing price", text: $session.macros.clearingPrice, prompt: Text(defaultPrice))
                    .help("${AUCTION_PRICE}. Empty: the bid price")
                TextField("Encrypted price", text: $session.macros.encryptedPrice, prompt: Text("none"))
                    .help("An opaque encrypted price substituted verbatim for ${AUCTION_PRICE} when set")
                TextField("Minimum to win", text: $session.macros.minimumToWin, prompt: Text("not sent"))
                    .help("${AUCTION_MIN_TO_WIN}")
                if let warning = priceWarning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Price")
            }

            Section {
                TextField("Auction ID", text: $session.macros.auctionID, prompt: Text(defaultAuctionID))
                    .help("${AUCTION_ID}. Empty: the bid request id, else the response id")
                TextField("Seat ID", text: $session.macros.seatID, prompt: Text(session.selectedCandidate?.seat ?? "the bid's seat"))
                    .help("${AUCTION_SEAT_ID}")
                Picker("Loss reason", selection: $session.macros.lossReason) {
                    ForEach(LossReason.lossReasons) { reason in
                        Text("\(reason.code) · \(reason.title)").tag(reason)
                    }
                }
                .help("${AUCTION_LOSS} for the Lose control")
            } header: {
                Text("Auction")
            }

            Section {
                Toggle("Exchange sends the win notice (nurl)", isOn: $session.macros.exchangeSendsWinNotice)
                Toggle("Deterministic timestamp, cache-buster and transaction id", isOn: $session.macros.deterministic)
                    .help("[TIMESTAMP] 2026-01-01T00:00:00Z, [CACHEBUSTING] 12345678: two runs produce identical URLs")
            } header: {
                Text("Options")
            }

            MacroEntriesSection(title: "Custom macros", footer: "${KEY} values; they override the bid's own bid.macro values.",
                                keyPrompt: "KEY", entries: $session.macros.customMacros)
            MacroEntriesSection(title: "Request values (fallbacks)",
                                footer: """
                                Bracketed VAST macros the pasted bid request does not supply; they replace the simulator's own \
                                defaults. List macros such as [BLOCKEDADCATEGORIES], [REGULATIONS] or [VASTVERSIONS] take \
                                comma-separated items (gdpr,coppa).
                                """,
                                keyPrompt: "[NAME]", entries: $session.macros.requestValues)
        }
        .formStyle(.grouped)
    }

    private var defaultPrice: String {
        session.selectedCandidate.map { InputSummary.price($0.price) } ?? "the bid price"
    }

    private var defaultAuctionID: String {
        session.parsed.request?.id ?? session.parsed.responseID ?? "the request id"
    }

    private var priceWarning: String? {
        let fields = [("Clearing price", session.macros.clearingPrice), ("Minimum to win", session.macros.minimumToWin)]
        for (name, value) in fields where !value.trimmingCharacters(in: .whitespaces).isEmpty && MacroSettings.price(value) == nil {
            return "\(name) is not a non-negative number; it is ignored"
        }
        return nil
    }
}

private struct MacroEntriesSection: View {
    let title: String
    let footer: String
    let keyPrompt: String
    @Binding var entries: [MacroEntry]

    var body: some View {
        Section {
            ForEach($entries) { $entry in
                HStack(spacing: 8) {
                    TextField("Key", text: $entry.key, prompt: Text(keyPrompt))
                        .font(Theme.monospaced)
                        .frame(maxWidth: 200)
                        .labelsHidden()
                    TextField("Value", text: $entry.value, prompt: Text("value"))
                        .font(Theme.monospaced)
                        .labelsHidden()
                    Button {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button {
                entries.append(MacroEntry(key: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(title)
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }
}
