import CcinnOpenRTBKit
import Foundation

/// The methods the Client sends: OpenRTB bid requests are POSTs; GET is for endpoints that take their query in the URL.
enum ClientMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case post = "POST"
    case get = "GET"

    var id: String { rawValue }

    /// Whether the body editor's text is sent.
    var sendsBody: Bool { self == .post }
}

/// One row of the headers editor.
struct ClientHeader: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var value: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, value: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var trimmedValue: String { value.trimmingCharacters(in: .whitespaces) }
    /// A row with neither name nor value: ignored.
    var isBlank: Bool { trimmedName.isEmpty && trimmedValue.isEmpty }
}

/// What the user composes in the Client tab: the method, the endpoint, the headers and the body as typed. Pure value:
/// `problems()` says what keeps it from being sent, `composed()` is exactly what the monitor sends.
struct ClientRequest: Codable, Hashable, Sendable {
    var method: ClientMethod
    var url: String
    var headers: [ClientHeader]
    var body: String

    init(method: ClientMethod = .post, url: String = "", headers: [ClientHeader] = ClientRequest.defaultHeaders(), body: String = "") {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// A JSON bid request with the version header OpenRTB recommends (2.6 §2.4 "Version HTTP Header").
    static func defaultHeaders() -> [ClientHeader] {
        [ClientHeader(name: "Content-Type", value: "application/json"), ClientHeader(name: "x-openrtb-version", value: "2.6")]
    }

    /// Why a request cannot be sent.
    enum Problem: Hashable, Sendable {
        case missingURL
        /// Not `http(s)` with a host.
        case invalidURL
        /// Not an RFC 9110 token (the name as typed, trimmed).
        case invalidHeaderName(String)
        /// A CR, LF or NUL would split or truncate the header (the header's name).
        case invalidHeaderValue(String)
        /// Two enabled headers share this name (any case; the later spelling).
        case duplicateHeader(String)

        var message: String {
            switch self {
            case .missingURL: "Enter the endpoint URL."
            case .invalidURL: "The URL must start with http:// or https:// and name a host."
            case let .invalidHeaderName(name): name.isEmpty ? "A header has a value but no name." : "“\(name)” is not a valid header name."
            case let .invalidHeaderValue(name): "The value of “\(name)” contains a line break or a NUL character."
            case let .duplicateHeader(name): "“\(name)” is set twice; turn one off."
            }
        }
    }

    /// The problems that keep the request from being sent.
    struct Invalid: Error, Hashable, Sendable {
        var problems: [Problem]
        var message: String { problems.map(\.message).joined(separator: " ") }
    }

    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The headers that are sent: enabled rows that are not blank.
    var activeHeaders: [ClientHeader] { headers.filter { $0.isEnabled && !$0.isBlank } }

    func problems() -> [Problem] {
        var problems: [Problem] = []
        if trimmedURL.isEmpty {
            problems.append(.missingURL)
        } else if !Self.isSendable(trimmedURL) {
            problems.append(.invalidURL)
        }
        var seen: Set<String> = []
        for header in activeHeaders {
            let name = header.trimmedName
            if !Self.isToken(name) {
                problems.append(.invalidHeaderName(name))
            } else if header.value.unicodeScalars.contains(where: Self.splitsAHeader) {
                problems.append(.invalidHeaderValue(name))
            } else if !seen.insert(name.lowercased()).inserted {
                problems.append(.duplicateHeader(name))
            }
        }
        return problems
    }

    /// Exactly what the monitor sends: the trimmed URL, the active headers (trimmed) and, for POST, the body as UTF-8.
    func composed() throws(Invalid) -> ComposedRequest {
        let problems = problems()
        guard problems.isEmpty else { throw Invalid(problems: problems) }
        var headers: [String: String] = [:]
        for header in activeHeaders { headers[header.trimmedName] = header.trimmedValue }
        return ComposedRequest(url: trimmedURL, method: method.rawValue, headers: headers, body: method.sendsBody ? Data(body.utf8) : nil)
    }

    /// A non-blocking note when a POST body is not JSON (it is still sent as typed).
    var jsonWarning: String? {
        guard method.sendsBody, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard (try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])) == nil else { return nil }
        return "The body is not valid JSON; it is sent as typed."
    }

    /// CR, LF and NUL. Checked on scalars, not Characters: "\r\n" is one Character, equal to neither "\r" nor "\n".
    private static func splitsAHeader(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\r" || scalar == "\n" || scalar == "\u{0}"
    }

    /// `http` or `https` with a host, as the monitor will send it.
    private static func isSendable(_ url: String) -> Bool {
        let scheme = URLText.scheme(url)
        guard scheme == "http" || scheme == "https" else { return false }
        return URLText.requestURL(url)?.host?.isEmpty == false
    }

    /// RFC 9110 §5.6.2 `token`: one or more of ALPHA, DIGIT and ``!#$%&'*+-.^_`|~``.
    static func isToken(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": true
            case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~": true
            default: false
            }
        }
    }
}
