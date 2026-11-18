import Foundation

/// "Copy as curl": a command that repeats the request in a POSIX shell.
///
/// - Every argument is single-quoted (`'` becomes `'\''`), so `$`, `;`, `&`, backticks and spaces stay literal.
/// - `--globoff` stops curl from treating VAST `[MACROS]` and `{…}` as URL globs.
/// - The URL is passed with `--url`, so a value starting with `-` is never read as an option.
/// - Control characters (which a shell argument cannot carry safely) are percent-encoded.
/// - The headers are the entry's, as sent on the wire when the transport reported them; with an `Accept-Encoding`
///   header, `--compressed` makes curl decode the compressed body it asked for (as browsers' "Copy as cURL" do).
/// - A request body goes in `--data-binary` (which implies POST, so `-X` is written only for another method), single
///   quoted with its newlines and tabs; other control characters become JSON `\u00XX` escapes (`bodyArgument`).
public enum CurlCommand {
    public static func make(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) -> String {
        var parts = ["curl", "--globoff"]
        let verb = method.uppercased()
        let impliedVerb = body == nil ? "GET" : "POST"
        if verb != impliedVerb, !verb.isEmpty { parts += ["-X", quote(verb)] }
        for header in HTTPHeaders.sorted(headers) {
            parts += ["-H", quote("\(header.name): \(header.value)")]
        }
        if HTTPHeaders.value("Accept-Encoding", in: headers) != nil { parts.append("--compressed") }
        if let body { parts += ["--data-binary", bodyArgument(body)] }
        parts += ["--url", quote(url)]
        return parts.joined(separator: " ")
    }

    /// The entry's request; `body` is its request body (`NetworkMonitor.requestBody(for:)`), if it had one.
    public static func make(for entry: NetworkEntry, body: Data? = nil) -> String {
        make(url: entry.url, method: entry.method, headers: entry.requestHeaders, body: body)
    }

    /// The body as one single-quoted argument. Tabs, line feeds and carriage returns stay (JSON whitespace; a quoted
    /// argument may span lines). Every other C0 / C1 control and DEL is written as its JSON escape `\u00XX`: a JSON text
    /// cannot contain them raw, and a terminal must never receive them (escape sequences).
    static func bodyArgument(_ body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                escaped.unicodeScalars.append(scalar)
            case 0x00..<0x20, 0x7F...0x9F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "'" + escaped.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// POSIX single quoting.
    public static func quote(_ argument: String) -> String {
        let safe = sanitized(argument)
        return "'" + safe.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sanitized(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                output += String(format: "%%%02X", scalar.value)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
