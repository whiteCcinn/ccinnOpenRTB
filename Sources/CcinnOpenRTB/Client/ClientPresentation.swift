import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI

/// What the Client tab shows, as plain values (tested without views).
enum ClientPresentation {
    enum StatusTone: Equatable {
        case success, redirect, clientError, serverError, other

        var color: Color {
            switch self {
            case .success: .green
            case .redirect: .blue
            case .clientError: .orange
            case .serverError: .red
            case .other: .secondary
            }
        }
    }

    /// "200 OK"; the bare code when the reason is not a standard one.
    static func statusText(_ status: Int) -> String {
        let reason = HTTPHeaders.reasonPhrase(status)
        return reason.isEmpty ? "\(status)" : "\(status) \(reason)"
    }

    static func statusTone(_ status: Int) -> StatusTone {
        switch status {
        case 200..<300: .success
        case 300..<400: .redirect
        case 400..<500: .clientError
        case 500..<600: .serverError
        default: .other
        }
    }

    /// Copy as curl for the draft: exactly what Send would put on the wire (the monitor's headers, overridden by the
    /// user's whatever their case, and the body).
    static func curl(for request: ClientRequest, userAgent: String, acceptLanguage: String) throws(ClientRequest.Invalid) -> String {
        let composed = try request.composed()
        let headers = HTTPHeaders.merged(NetworkMonitor.requestHeaders(userAgent: userAgent, language: acceptLanguage), overriddenBy: composed.headers)
        return CurlCommand.make(url: composed.url, method: composed.wireMethod, headers: headers, body: composed.wireBody,
                                followsRedirects: composed.redirects == .all)
    }

    /// Saved requests whose name, method or URL contain every word of `query` (case-insensitive).
    static func filter(_ requests: [SavedRequest], by query: String) -> [SavedRequest] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return requests }
        return requests.filter { saved in
            let haystack = [saved.name, saved.request.method.rawValue, saved.request.url].joined(separator: "\n").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func title(for policy: RedirectPolicy) -> String {
        switch policy {
        case .all: "Follow all redirects"
        case .sameOrigin: "Follow redirects within the origin"
        case .none: "Don’t follow redirects"
        }
    }

    static func shortTitle(for policy: RedirectPolicy) -> String {
        switch policy {
        case .all: "Redirects: all"
        case .sameOrigin: "Redirects: same origin"
        case .none: "Redirects: off"
        }
    }

    static func help(for policy: RedirectPolicy) -> String {
        switch policy {
        case .all: "Every redirect is followed, to other origins too (Authorization, Proxy-Authorization and Cookie stay behind; other headers and, on 307/308, the body go along)"
        case .sameOrigin: "Redirects within the endpoint’s scheme, host and port are followed; one anywhere else is the answer"
        case .none: "The first 3xx is the answer"
        }
    }

    /// "via 2 redirects", or `nil` without any.
    static func redirectsLine(_ response: ClientResponse) -> String? {
        switch response.redirectCount {
        case 0: nil
        case 1: "via 1 redirect"
        case let count: "via \(count) redirects"
        }
    }

    /// "POST ssp.example/openrtb2/auction".
    static func requestLine(_ request: ClientRequest) -> String {
        let place = URLText.hostAndPath(request.trimmedURL)
        return request.method.rawValue + " " + (place.isEmpty ? "no URL" : place)
    }

    /// "Received 14:02:11" or "Saved response · 18 Nov 2026 at 14:02".
    static func origin(of exchange: ClientExchange, _ origin: ClientModel.ExchangeOrigin?) -> String {
        let received = exchange.response.receivedAt
        switch origin {
        case .saved?: return "Saved response · " + received.formatted(date: .abbreviated, time: .shortened)
        case .sent?, nil: return "Received " + received.formatted(date: .omitted, time: .standard)
        }
    }

    /// What the simulator made of the exchange: "OpenRTB 2.6 · 1 bid · Video · Rewarded · iPhone 18 Pro".
    @MainActor
    static func simulatorSummary(_ session: AdSession) -> String {
        var parts = [InputSummary.status(of: session.parsed, issues: session.issues, isParsing: session.isParsing)]
        if let candidate = session.selectedCandidate { parts.append(InputSummary.formatTitle(candidate.format)) }
        parts.append(session.placement.rawValue)
        parts.append(session.device.name)
        return parts.joined(separator: " · ")
    }
}
