import CcinnOpenRTBKit
import Foundation
import RTBKit

/// The Sync tab's words, as plain values (tested without views).
enum SyncPresentation {
    static func title(for policy: CookiePolicy) -> String {
        switch policy {
        case .allowThirdParty: "Third-party cookies allowed"
        case .blockThirdParty: "Third-party cookies blocked"
        case .partitioned: "Third-party cookies partitioned"
        }
    }

    static func browsers(for policy: CookiePolicy) -> String {
        switch policy {
        case .allowThirdParty: "Chrome and Chromium browsers, Android web views: SameSite=None; Secure required, a missing SameSite is Lax"
        case .blockThirdParty: "WebKit: Safari, and every in-app web view on iPhone and iPad"
        case .partitioned: "Firefox (Total Cookie Protection): kept per top-level site"
        }
    }

    static func explain(_ rejection: CookieRejection) -> String {
        switch rejection {
        case .malformed: "malformed Set-Cookie (no name=value)"
        case .tooLarge: "name and value exceed 4096 bytes"
        case .secureFromInsecureOrigin: "Secure cookie sent over http"
        case .sameSiteNoneWithoutSecure: "SameSite=None without Secure"
        case .partitionedWithoutSecure: "Partitioned without Secure"
        case let .prefix(prefix): "\(prefix) prefix rules not met"
        case let .publicSuffix(domain): "Domain=\(domain) is a public suffix"
        case let .domainMismatch(domain): "Domain=\(domain) does not cover the host"
        case .thirdPartyBlocked: "third-party cookies are blocked in this browser"
        case let .sameSiteCrossSite(sameSite):
            sameSite == .lax ? "SameSite=Lax (or no SameSite: Lax by default) from a cross-site response" : "SameSite=\(name(of: sameSite)) from a cross-site response"
        }
    }

    static func explain(_ withheld: CookieWithheld) -> String {
        switch withheld {
        case .thirdPartyBlocked: "not sent: third-party cookies are blocked"
        case let .sameSite(sameSite): "not sent: SameSite=\(name(of: sameSite)) on a cross-site request"
        case .secureOnly: "not sent: Secure, and the request is http"
        case .partitionedElsewhere: "not sent: kept for another top-level site"
        }
    }

    static func name(of sameSite: SameSite) -> String {
        switch sameSite {
        case .strict: "Strict"
        case .lax: "Lax"
        case .none: "None"
        case .unspecified: "(none)"
        }
    }

    /// "uid=abc123 · Domain=dsp.example · Path=/ · Secure · SameSite=None · expires in 1 h".
    static func describe(_ cookie: StoredCookie, now: Date) -> String {
        var parts = ["\(cookie.name)=\(cookie.value.count > 80 ? String(cookie.value.prefix(80)) + "…" : cookie.value)"]
        parts.append(cookie.hostOnly ? "host \(cookie.domain)" : "Domain=\(cookie.domain)")
        parts.append("Path=\(cookie.path)")
        if cookie.secure { parts.append("Secure") }
        if cookie.httpOnly { parts.append("HttpOnly") }
        if cookie.sameSite != .unspecified { parts.append("SameSite=\(name(of: cookie.sameSite))") }
        if let partition = cookie.partitionSite { parts.append("partitioned for \(partition)") }
        parts.append(cookie.expires.map { "expires in " + span(from: now, to: $0) } ?? "session")
        return parts.joined(separator: " · ")
    }

    static func span(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        switch seconds {
        case ..<60: return "\(Int(seconds)) s"
        case ..<3_600: return "\(Int(seconds / 60)) min"
        case ..<86_400: return "\(Int(seconds / 3_600)) h"
        default: return "\(Int(seconds / 86_400)) d"
        }
    }

    /// What the run means, most important first.
    static func verdicts(for run: SyncRun, policy: CookiePolicy) -> [String] {
        var verdicts: [String] = []
        let host: (Int) -> String = { index in
            run.response.chain.indices.contains(index) ? URLText.hostAndPath(run.response.chain[index].url).prefix(60) + "" : "?"
        }
        for leftover in run.leftovers {
            verdicts.append("\(leftover.placeholder) was not substituted in hop \(leftover.hopIndex + 1) (\(host(leftover.hopIndex))): the match is lost.")
        }
        for mapping in run.mappings {
            let partner = mapping.partner.map { "\($0) → " } ?? ""
            verdicts.append("Mapped: \(partner)\(mapping.parameter)=\(mapping.id), passed to \(host(mapping.hopIndex)) (hop \(mapping.hopIndex + 1)).")
        }
        let blocked = run.decisions.filter { if case .rejected(_, .thirdPartyBlocked) = $0 { true } else { false } }.count
        if blocked > 0 {
            verdicts.append("This browser blocks third-party cookies (\(browsers(for: .blockThirdParty))): \(blocked) cookie\(blocked == 1 ? " was" : "s were") "
                + "not stored, so the partners will not recognise this user next time.")
        }
        let otherRejections = run.decisions.compactMap { decision -> String? in
            if case let .rejected(name, reason) = decision, reason != .thirdPartyBlocked { return "\(name.isEmpty ? "a cookie" : name): \(explain(reason))" }
            return nil
        }
        if !otherRejections.isEmpty { verdicts.append("Rejected — " + otherRejections.joined(separator: "; ") + ".") }
        if let stop = run.response.redirectStop { verdicts.append("The chain stopped: \(stop)") }
        if !(200..<400).contains(run.response.status) { verdicts.append("The chain ended with HTTP \(run.response.status).") }
        if run.mappings.isEmpty, run.leftovers.isEmpty { verdicts.append("No user id was passed along the chain.") }
        if !run.unknownMacros.isEmpty { verdicts.append("Left as is in the start URL: " + run.unknownMacros.joined(separator: ", ") + ".") }
        _ = policy
        return verdicts
    }
}
