import Foundation

/// "Copy as curl": a command that repeats the request in a POSIX shell.
///
/// - Every argument is single-quoted (`'` becomes `'\''`), so `$`, `;`, `&`, backticks and spaces stay literal.
/// - `--globoff` stops curl from treating VAST `[MACROS]` and `{…}` as URL globs.
/// - The URL is passed with `--url`, so a value starting with `-` is never read as an option.
/// - Control characters (which a shell argument cannot carry safely) are percent-encoded.
/// - The headers are the entry's, as sent on the wire when the transport reported them; with an `Accept-Encoding`
///   header, `--compressed` makes curl decode the compressed body it asked for (as browsers' "Copy as cURL" do).
public enum CurlCommand {
    public static func make(url: String, method: String = "GET", headers: [String: String] = [:]) -> String {
        var parts = ["curl", "--globoff"]
        let verb = method.uppercased()
        if verb != "GET", !verb.isEmpty { parts += ["-X", quote(verb)] }
        for header in HTTPHeaders.sorted(headers) {
            parts += ["-H", quote("\(header.name): \(header.value)")]
        }
        if HTTPHeaders.value("Accept-Encoding", in: headers) != nil { parts.append("--compressed") }
        parts += ["--url", quote(url)]
        return parts.joined(separator: " ")
    }

    public static func make(for entry: NetworkEntry) -> String {
        make(url: entry.url, method: entry.method, headers: entry.requestHeaders)
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
