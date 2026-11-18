import Foundation
import RTBKit

/// Texts that summarise the pasted input (pure): the status line under the editor and the bid picker's titles.
enum InputSummary {
    /// "OpenRTB 2.6 · 2 bids · 1 issue".
    static func status(of input: ParsedInput, issues: [ValidationIssue], isParsing: Bool) -> String {
        if isParsing { return "Parsing…" }
        let kind: String
        switch input.kind {
        case .empty: return "Paste a bid response, Native, VAST or HTML"
        case let .bidResponse(version): kind = version.description
        case .nativeMarkup: kind = "Native markup"
        case .vastMarkup: kind = "VAST markup"
        case .vastURL: kind = "VAST tag URL"
        case .htmlMarkup: kind = "HTML markup"
        case let .invalid(reason): return "Not recognised: \(reason) · " + count(issues.count, "issue", none: "no issues")
        }
        var bids = count(input.candidates.count, "bid", none: "no bid")
        if input.candidates.isEmpty, let reason = input.noBidReason { bids += " (nbr \(reason))" }
        return [kind, bids, count(issues.count, "issue", none: "no issues")].joined(separator: " · ")
    }

    static func worstSeverity(_ issues: [ValidationIssue]) -> ValidationIssue.Severity? {
        issues.map(\.severity).max()
    }

    /// "bid-1 · seat-a · 2.50 USD · Banner 320×50 · deal d-7".
    static func title(of candidate: AdCandidate) -> String {
        var parts = [candidate.bidID.isEmpty ? "bid \(candidate.id)" : candidate.bidID]
        if let seat = candidate.seat, !seat.isEmpty { parts.append(seat) }
        parts.append("\(price(candidate.price)) \(candidate.currency)")
        var format = formatTitle(candidate.format)
        if let size = candidate.size { format += " \(size.width)×\(size.height)" }
        parts.append(format)
        if let deal = candidate.dealID, !deal.isEmpty { parts.append("deal \(deal)") }
        return parts.joined(separator: " · ")
    }

    static func formatTitle(_ format: AdFormat) -> String {
        switch format {
        case .banner: "Banner"
        case .native: "Native"
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    /// Two to four decimals, independent of the user's locale (prices are protocol values): 2.50, 0.1234.
    static func price(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        var text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 3 {
            text.removeLast()
        }
        return text
    }

    private static func count(_ value: Int, _ noun: String, none: String) -> String {
        switch value {
        case 0: none
        case 1: "1 \(noun)"
        default: "\(value) \(noun)s"
        }
    }
}
