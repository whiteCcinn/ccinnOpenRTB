import Foundation
import RTBKit

/// Format for everything that shows ad markup — the Response and Request editors, the Inspector's Markup, response
/// bodies (pure): text copied out of a JSON string is unescaped first, then JSON, VAST / XML or HTML is pretty-printed
/// without changing what it means (`JSONFormatter`, `TagFormatter`).
enum MarkupFormatter {
    enum Language: Equatable, Sendable {
        case json, vast, xml, html

        var title: String {
            switch self {
            case .json: "JSON"
            case .vast: "VAST XML"
            case .xml: "XML"
            case .html: "HTML"
            }
        }
    }

    struct Formatted: Equatable, Sendable {
        var text: String
        /// `nil` when the text was only unescaped: `problem` says why it was not pretty-printed.
        var language: Language?
        /// How many times it was unescaped from a JSON string first (0: it was not escaped).
        var unescapedLevels: Int
        var problem: Failure?

        /// "Unescaped a JSON string · VAST XML", "HTML", "Unescaped twice · Not well-formed XML: …".
        var summary: String {
            var parts: [String] = []
            switch unescapedLevels {
            case 0: break
            case 1: parts.append("Unescaped a JSON string")
            case 2: parts.append("Unescaped twice")
            default: parts.append("Unescaped \(unescapedLevels) times")
            }
            if let language { parts.append(language.title) }
            if let problem { parts.append(problem.message) }
            return parts.joined(separator: " · ")
        }
    }

    enum Failure: Error, Equatable, Sendable {
        case empty
        case notMarkup
        case json
        case xml(TagFormatter.Failure)
        case html(TagFormatter.Failure)

        var message: String {
            switch self {
            case .empty: "Nothing to format"
            case .notMarkup: "Nothing to format: not JSON, XML or HTML"
            case .json: "Not well-formed JSON: unbalanced brackets or an open string"
            case let .xml(failure): "Not well-formed XML: " + Self.describe(failure, rawText: "CDATA section")
            case let .html(failure): "Not well-formed HTML: " + Self.describe(failure, rawText: "script")
            }
        }

        private static func describe(_ failure: TagFormatter.Failure, rawText: String) -> String {
            switch failure {
            case .empty: "nothing to format"
            case let .unterminated(line): "a tag, comment or \(rawText) is not closed (line \(line))"
            case let .mismatched(open, close, line): "</\(close)> closes <\(open)> (line \(line))"
            case let .unexpectedClose(name, line): "</\(name)> closes nothing (line \(line))"
            case let .unclosed(name, line): "<\(name)> is not closed (line \(line))"
            }
        }
    }

    /// Unescapes and pretty-prints `text`. `hint` (from a MIME type) chooses XML over HTML for markup that does not say.
    /// Succeeds when the text was unescaped, pretty-printed or both.
    static func format(_ text: String, as hint: Language? = nil) -> Result<Formatted, Failure> {
        let unescaped = JSONEscapedText.unescaped(text)
        let source = (unescaped?.text ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        let levels = unescaped?.levels ?? 0
        let pretty = prettyPrinted(source, hint: hint)
        switch pretty {
        case let .success((output, language)):
            return .success(Formatted(text: output, language: language, unescapedLevels: levels))
        case let .failure(failure):
            guard levels > 0 else { return .failure(failure) }
            return .success(Formatted(text: source, language: nil, unescapedLevels: levels, problem: failure))
        }
    }

    /// Whether Format can do anything: the text starts like JSON, markup or a JSON string (cheap; enables the button).
    static func mightFormat(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
        return ["{", "[", "<", "\"", "\\"].contains(first)
    }

    /// The formatted text for a viewer, or the text itself when it cannot be formatted.
    static func displayText(_ text: String, as hint: Language? = nil) -> String {
        (try? format(text, as: hint).get())?.text ?? text
    }

    /// `trimmed` has no surrounding whitespace.
    private static func prettyPrinted(_ trimmed: String, hint: Language?) -> Result<(String, Language), Failure> {
        guard let first = trimmed.first else { return .failure(.empty) }
        switch first {
        case "{", "[":
            guard let json = JSONFormatter.prettyPrinted(trimmed) else { return .failure(.json) }
            return .success((json, .json))
        case "<":
            let language = markupLanguage(trimmed, hint: hint)
            switch TagFormatter.prettyPrinted(trimmed, dialect: language == .html ? .html : .xml) {
            case let .success(output): return .success((output, language))
            case let .failure(failure): return .failure(language == .html ? .html(failure) : .xml(failure))
            }
        default:
            return .failure(.notMarkup)
        }
    }

    /// VAST for a `VAST` root (any case, any prefix), XML for an XML declaration or another XML ad format's root
    /// (`VMAP`, `DAAST`) or an XML `hint`, HTML otherwise.
    static func markupLanguage(_ trimmed: String, hint: Language? = nil) -> Language {
        let root = rootElementName(trimmed)?.lowercased()
        let localName = root.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
        if localName == "vast" { return .vast }
        if localName == "vmap" || localName == "daast" || trimmed.hasPrefix("<?xml") { return .xml }
        return hint == .xml || hint == .vast ? .xml : .html
    }

    /// The first element's name after the prolog (declarations, comments, a DOCTYPE).
    private static func rootElementName(_ text: String) -> String? {
        var rest = Substring(text)
        for _ in 0..<64 { // bounded: each pass removes one prolog item
            rest = rest.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return nil }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<?") || rest.hasPrefix("<!") {
                guard let end = rest.firstIndex(of: ">") else { return nil }
                rest = rest[rest.index(after: end)...]
            } else {
                break
            }
        }
        guard rest.hasPrefix("<") else { return nil }
        let name = rest.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" || $0 == "_" || $0 == "." }
        return name.isEmpty ? nil : String(name)
    }
}
