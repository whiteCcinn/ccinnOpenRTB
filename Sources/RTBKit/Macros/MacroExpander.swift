import Foundation

/// OpenRTB `${…}` and VAST `[…]` macro expansion (design D4). Owner: kit-openrtb.
///
/// Rules:
/// - One left-to-right pass: substituted values are never scanned again, so a value that looks like a macro stays literal.
/// - Values are percent-encoded once (RFC 3986 unreserved characters kept). The template itself is never re-encoded.
/// - `${AUCTION_PRICE}` / `${OPENRTB_PRICE}` with an encrypted price set: the encrypted string, verbatim. `${…:B64}` is the
///   base64url (RFC 4648 §5, no padding) of the clear value. Any other `:X` suffix is an algorithm agreed between the
///   parties: the price macros take the encrypted price verbatim when one is set; everything else is unknown.
/// - OpenRTB 3.0 buyer macros (`bid.macro`) are `${CUSTOM_KEY}`; a bare `${KEY}` also resolves from `MacroContext.custom`
///   (user-defined exchange macros). Standard macros win over custom keys of the same name.
/// - A known OpenRTB macro without a value becomes the empty string (and is listed as replaced). A known VAST macro without
///   a value becomes `-1` (VAST 4.1 §6.1 "unknown").
/// - Unknown macros are left in place and reported. Percent-encoded macros (`%24%7BAUCTION_PRICE%7D`) are reported too:
///   exchanges and players substitute only the literal token.
///
/// Which family a fire-time expansion substitutes depends on the document the URL was written in (decisions.md "Macros"):
/// - the bid response's own URLs (nurl/burl/lurl, 3.0 purl/burl/lurl, AdCOM `display.event`, the AdCOM banner `link`):
///   OpenRTB `${…}` only, as the exchange does (`expandOpenRTB`; OpenRTB 2.6 §4.4);
/// - VAST documents from any hop: VAST `[…]` only, as the player does (`expandVAST`; VAST 4.1 §6.1/§6.2). The exchange
///   substituted `${…}` in an inline `adm` before the player saw it (`expandMarkup`); a `${…}` in a document a request
///   delivered was never substituted and stays literal, reported;
/// - Native trackers and links: nothing (the SDK fires them as written; an inline `adm` was substituted beforehand).
public enum MacroExpander {
    /// Both families at once (`${…}` and `[…]`), for callers that know a URL went through the exchange and the player.
    /// Fire-time tracking uses the origin-specific entry points instead (see the type's notes).
    public static func expand(_ template: String, context: MacroContext) -> ExpandedURL {
        expand(template, context: context, timeZone: deviceClock(of: context))
    }

    /// `timeZone` is the device clock used for `[TIMESTAMP]` (tests pin it; the other entry points use `deviceClock(of:)`).
    public static func expand(_ template: String, context: MacroContext, timeZone: TimeZone) -> ExpandedURL {
        var resolver = MacroValueResolver(context: context, timeZone: timeZone)
        return MacroScanner.substitute(in: template, mode: .url, resolver: &resolver)
    }

    /// An OpenRTB / Native / AdCOM tracker (`nurl`, `burl`, `lurl`, `imptrackers`, `eventtrackers`, `display.event`): only
    /// the exchange substitutes these, so only `${…}` is expanded. VAST-style `[NAME]` tokens stay literal and are reported.
    public static func expandOpenRTB(_ template: String, context: MacroContext) -> ExpandedURL {
        var resolver = MacroValueResolver(context: context, timeZone: deviceClock(of: context))
        return MacroScanner.substitute(in: template, mode: .openRTBURL, resolver: &resolver)
    }

    /// Exchange-side substitution in `adm` (HTML, Native JSON or VAST XML) and in Native `jstracker` markup: only OpenRTB
    /// `${…}` macros, because `[…]` and lower-case `${…}` are ordinary JavaScript there (and VAST `[…]` belongs to the player).
    /// Unknown `${UPPER_CASE}` tokens are still reported.
    public static func expandMarkup(_ markup: String, context: MacroContext) -> ExpandedURL {
        var resolver = MacroValueResolver(context: context, timeZone: deviceClock(of: context))
        return MacroScanner.substitute(in: markup, mode: .markup, resolver: &resolver)
    }

    /// A URL in a VAST document, from any hop (the player's view, VAST 4.1 §6.1/§6.2): VAST `[…]` macros are substituted;
    /// OpenRTB `${…}` is not a player macro, so it stays literal and is listed in `unknown` (an inline `adm` had it
    /// substituted by the exchange already; a fetched document never did). Also for VAST request URIs (`VASTAdTagURI`, a
    /// pasted or `curl` VAST tag URL).
    public static func expandVAST(_ template: String, context: MacroContext) -> ExpandedURL {
        var resolver = MacroValueResolver(context: context, timeZone: deviceClock(of: context))
        return MacroScanner.substitute(in: template, mode: .vastURL, resolver: &resolver)
    }

    /// The OpenRTB `${…}` macros left in a document the exchange never substituted (markup fetched from the win notice or
    /// AdCOM `curl`, a VAST wrapper's response, …), in first-seen order: every upper-case `${NAME}` / `${NAME:ALG}` and its
    /// percent-encoded form. Creative markup rules apply, so JavaScript template literals (`${width}`) and `[…]` are not
    /// reported. For the host's own "unsubstituted macro" warning on fetched HTML and Native documents.
    public static func unsubstitutedOpenRTBMacros(in document: String) -> [String] {
        var resolver = MacroValueResolver(context: MacroContext(), timeZone: .gmt)
        return MacroScanner.substitute(in: document, mode: .literalMarkup, resolver: &resolver).unknown
    }

    /// A URL fired exactly as written (Native trackers and links at fire time): nothing is substituted; `${…}` and `[…]`
    /// tokens are reported in `unknown`.
    static func literal(_ template: String) -> ExpandedURL {
        var resolver = MacroValueResolver(context: MacroContext(), timeZone: .gmt)
        return MacroScanner.substitute(in: template, mode: .literalURL, resolver: &resolver)
    }

    /// Script markup injected exactly as written (Native `jstracker` at fire time): nothing is substituted; upper-case
    /// `${…}` tokens are reported in `unknown`.
    static func literalMarkup(_ markup: String) -> ExpandedURL {
        var resolver = MacroValueResolver(context: MacroContext(), timeZone: .gmt)
        return MacroScanner.substitute(in: markup, mode: .literalMarkup, resolver: &resolver)
    }

    /// The `${…}` tokens (any case, and their percent-encoded forms) in a URL, or the upper-case ones in markup
    /// (`isMarkup`), in first-seen order. Nothing is substituted.
    static func openRTBTokens(in text: String, isMarkup: Bool) -> [String] {
        guard text.utf8.contains(where: { $0 == UInt8(ascii: "$") || $0 == UInt8(ascii: "%") }) else { return [] }
        let tokens = isMarkup ? literalMarkup(text).unknown : literal(text).unknown
        return tokens.filter { $0.hasPrefix("$") || $0.hasPrefix("%24") }
    }

    /// The simulated device's clock (VAST 4.1 §6.2 `[TIMESTAMP]` carries its UTC offset): `DeviceProfile.timeZone` when
    /// Foundation knows the identifier, otherwise UTC. Never `TimeZone.current`, the Mac's zone.
    static func deviceClock(of context: MacroContext) -> TimeZone {
        context.device?.timeZone.flatMap(TimeZone.init(identifier:)) ?? .gmt
    }
}

// MARK: - Scanner

/// Single-pass byte scanner. Recognised tokens:
/// - `${NAME}` / `${NAME:ALG}` with `NAME` = `[A-Za-z0-9_]+`, `ALG` = `[A-Za-z0-9]+`;
/// - `[NAME]` with `NAME` = `[A-Z][A-Z0-9_]*` (VAST);
/// - `%24%7BNAME%7D`, `%24%7BNAME%3AALG%7D` and `%5BNAME%5D` (percent-encoded forms, reported only).
enum MacroScanner {
    enum Mode {
        /// Both families.
        case url
        /// OpenRTB tracker URLs: `${…}` substituted; `[NAME]` left and reported.
        case openRTBURL
        /// VAST URLs: `[NAME]` substituted; `${…}` left and reported.
        case vastURL
        /// URLs fired as written: nothing substituted; `${…}` and `[NAME]` reported.
        case literalURL
        /// Creative markup: OpenRTB family only; `[…]` ignored; unknown `${…}` reported only when upper-case.
        case markup
        /// Creative markup kept as written: nothing substituted; upper-case `${…}` reported.
        case literalMarkup

        var substitutesOpenRTB: Bool {
            switch self {
            case .url, .openRTBURL, .markup: true
            case .vastURL, .literalURL, .literalMarkup: false
            }
        }

        var substitutesVAST: Bool {
            switch self {
            case .url, .vastURL: true
            case .openRTBURL, .literalURL, .markup, .literalMarkup: false
            }
        }

        /// In markup `[…]` is JavaScript or text, and a lower-case `${…}` a template literal: neither is a macro.
        var isMarkup: Bool {
            switch self {
            case .markup, .literalMarkup: true
            case .url, .openRTBURL, .vastURL, .literalURL: false
            }
        }
    }

    private static let dollar = UInt8(ascii: "$"), openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]"), colon = UInt8(ascii: ":")
    private static let percent = UInt8(ascii: "%"), underscore = UInt8(ascii: "_")

    static func substitute(in template: String, mode: Mode, resolver: inout MacroValueResolver) -> ExpandedURL {
        let bytes = Array(template.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 32)
        var replaced = OrderedTokens()
        var unknown = OrderedTokens()
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == dollar, let token = scanOpenRTB(bytes, at: index) {
                let literal = String(decoding: bytes[index..<token.end], as: UTF8.self)
                if mode.substitutesOpenRTB, let value = resolver.openRTBValue(name: token.name, algorithm: token.algorithm) {
                    output.append(contentsOf: value.utf8)
                    replaced.insert(literal)
                } else {
                    output.append(contentsOf: bytes[index..<token.end])
                    if !mode.isMarkup || isUpperCaseName(token.name) { unknown.insert(literal) }
                }
                index = token.end
                continue
            }
            if byte == openBracket, !mode.isMarkup, let token = scanVAST(bytes, at: index) {
                let literal = String(decoding: bytes[index..<token.end], as: UTF8.self)
                if mode.substitutesVAST, let value = resolver.vastValue(name: token.name) {
                    output.append(contentsOf: value.utf8)
                    replaced.insert(literal)
                } else {
                    output.append(contentsOf: bytes[index..<token.end])
                    unknown.insert(literal)
                }
                index = token.end
                continue
            }
            if byte == percent, let end = scanEncodedMacro(bytes, at: index, includeVAST: !mode.isMarkup) {
                output.append(contentsOf: bytes[index..<end])
                unknown.insert(String(decoding: bytes[index..<end], as: UTF8.self))
                index = end
                continue
            }
            output.append(byte)
            index += 1
        }
        return ExpandedURL(url: String(decoding: output, as: UTF8.self), replaced: replaced.values, unknown: unknown.values)
    }

    // MARK: Token scanning

    private struct OpenRTBToken {
        var name: String
        var algorithm: String?
        var end: Int
    }

    private struct VASTToken {
        var name: String
        var end: Int
    }

    private static func scanOpenRTB(_ bytes: [UInt8], at start: Int) -> OpenRTBToken? {
        guard start + 1 < bytes.count, bytes[start + 1] == openBrace else { return nil }
        let nameStart = start + 2
        var cursor = nameStart
        while cursor < bytes.count, isNameByte(bytes[cursor]) { cursor += 1 }
        guard cursor > nameStart, cursor < bytes.count else { return nil }
        let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self)
        var algorithm: String?
        if bytes[cursor] == colon {
            let algorithmStart = cursor + 1
            cursor = algorithmStart
            while cursor < bytes.count, isAlphanumeric(bytes[cursor]) { cursor += 1 }
            guard cursor > algorithmStart, cursor < bytes.count else { return nil }
            algorithm = String(decoding: bytes[algorithmStart..<cursor], as: UTF8.self)
        }
        guard bytes[cursor] == closeBrace else { return nil }
        return OpenRTBToken(name: name, algorithm: algorithm, end: cursor + 1)
    }

    private static func scanVAST(_ bytes: [UInt8], at start: Int) -> VASTToken? {
        let nameStart = start + 1
        guard nameStart < bytes.count, isUpperLetter(bytes[nameStart]) else { return nil }
        var cursor = nameStart + 1
        while cursor < bytes.count, isVASTNameByte(bytes[cursor]) { cursor += 1 }
        guard cursor < bytes.count, bytes[cursor] == closeBracket else { return nil }
        return VASTToken(name: String(decoding: bytes[nameStart..<cursor], as: UTF8.self), end: cursor + 1)
    }

    /// Matches `%24%7BNAME[%3AALG]%7D` (and, for URLs, `%5BNAME%5D`), hex digits case-insensitive.
    private static func scanEncodedMacro(_ bytes: [UInt8], at start: Int, includeVAST: Bool) -> Int? {
        if matchesEscape(bytes, at: start, 0x32, 0x34), matchesEscape(bytes, at: start + 3, 0x37, 0x42) { // %24 %7B
            var cursor = start + 6
            let nameStart = cursor
            while cursor < bytes.count, isNameByte(bytes[cursor]) { cursor += 1 }
            guard cursor > nameStart else { return nil }
            if matchesEscape(bytes, at: cursor, 0x33, 0x41) { // %3A
                cursor += 3
                let algorithmStart = cursor
                while cursor < bytes.count, isAlphanumeric(bytes[cursor]) { cursor += 1 }
                guard cursor > algorithmStart else { return nil }
            }
            return matchesEscape(bytes, at: cursor, 0x37, 0x44) ? cursor + 3 : nil // %7D
        }
        if includeVAST, matchesEscape(bytes, at: start, 0x35, 0x42) { // %5B
            var cursor = start + 3
            guard cursor < bytes.count, isUpperLetter(bytes[cursor]) else { return nil }
            while cursor < bytes.count, isVASTNameByte(bytes[cursor]) { cursor += 1 }
            return matchesEscape(bytes, at: cursor, 0x35, 0x44) ? cursor + 3 : nil // %5D
        }
        return nil
    }

    /// `%XY` at `index` (`high`/`low` are the upper-case ASCII hex digits), case-insensitive.
    private static func matchesEscape(_ bytes: [UInt8], at index: Int, _ high: UInt8, _ low: UInt8) -> Bool {
        guard index >= 0, index + 2 < bytes.count, bytes[index] == percent else { return false }
        return asciiUpper(bytes[index + 1]) == high && asciiUpper(bytes[index + 2]) == low
    }

    private static func isUpperCaseName(_ name: String) -> Bool {
        var hasLetter = false
        for byte in name.utf8 {
            if isUpperLetter(byte) { hasLetter = true } else if !(isDigit(byte) || byte == underscore) { return false }
        }
        return hasLetter
    }

    private static func isNameByte(_ byte: UInt8) -> Bool { isAlphanumeric(byte) || byte == underscore }
    private static func isVASTNameByte(_ byte: UInt8) -> Bool { isUpperLetter(byte) || isDigit(byte) || byte == underscore }
    private static func isAlphanumeric(_ byte: UInt8) -> Bool { isUpperLetter(byte) || isDigit(byte) || (byte >= 0x61 && byte <= 0x7A) }
    private static func isUpperLetter(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func asciiUpper(_ byte: UInt8) -> UInt8 { (byte >= 0x61 && byte <= 0x7A) ? byte - 0x20 : byte }
}

/// Distinct strings in first-seen order.
struct OrderedTokens {
    private(set) var values: [String] = []
    private var seen: Set<String> = []

    mutating func insert(_ value: String) {
        if seen.insert(value).inserted { values.append(value) }
    }
}
