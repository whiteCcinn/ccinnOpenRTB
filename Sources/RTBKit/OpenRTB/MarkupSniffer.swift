import Foundation

/// Recognises what a piece of markup is (D3 detection and the 2.x `adm` sniff): string inspection, plus a JSON parse to tell Native.
enum MarkupSniffer {
    enum Kind: Equatable {
        case vast
        case native
        case url
        case html
    }

    static func kind(of markup: String) -> Kind {
        let trimmed = markup.trimmingCharacters(in: .whitespacesAndNewlines)
        if isVASTDocument(trimmed) { return .vast }
        if isHTTPURL(trimmed) { return .url }
        if trimmed.hasPrefix("{") {
            do {
                if isNativeObject(try JSONValue.parse(trimmed)) { return .native }
            } catch {
                // Native is the only JSON markup `adm` carries; the Native parser then reports the nesting.
                if case .nestedTooDeeply = error.reason { return .native }
            }
        }
        return .html
    }

    /// The root element (after an XML declaration, comments, a DOCTYPE and whitespace) is `<VAST`.
    static func isVASTDocument(_ text: String) -> Bool {
        var rest = Substring(text)
        if rest.hasPrefix("\u{FEFF}") { rest = rest.dropFirst() }
        for _ in 0..<64 { // bounded: each pass removes one prolog item
            rest = rest.drop(while: \.isWhitespace)
            if rest.hasPrefix("<?") {
                guard let end = rest.range(of: "?>") else { return false }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return false }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<!") {
                guard let end = rest.firstIndex(of: ">") else { return false }
                rest = rest[rest.index(after: end)...]
            } else {
                break
            }
        }
        guard rest.hasPrefix("<VAST") else { return false }
        let after = rest.dropFirst(5).first
        return after == nil || after == ">" || after == "/" || after?.isWhitespace == true
    }

    /// A single absolute `http(s)://` URL with no whitespace inside.
    static func isHTTPURL(_ text: String) -> Bool {
        let lowered = text.prefix(8).lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return false }
        return !text.contains(where: \.isWhitespace) && URLRules.isAbsoluteHTTPURL(text)
    }

    /// A Native response object: wrapped (`native`) or with `assets` / `link` (or AdCOM `asset`).
    static func isNativeObject(_ value: JSONValue) -> Bool {
        guard case let .object(members) = value else { return false }
        return members["native"] != nil || members["assets"] != nil || members["link"] != nil || members["asset"] != nil
    }

    /// Every typed `<MediaFile>` is audio (`type="audio/…"`): an audio-only VAST ad.
    static func vastLooksAudioOnly(_ xml: String) -> Bool {
        var sawAudio = false
        var searchRange = xml.startIndex..<xml.endIndex
        while let open = xml.range(of: "<MediaFile", range: searchRange) {
            guard let close = xml.range(of: ">", range: open.upperBound..<xml.endIndex) else { break }
            let tag = xml[open.upperBound..<close.lowerBound].lowercased()
            if tag.contains("type=\"video/") || tag.contains("type='video/") || tag.contains("x-mpegurl") { return false }
            if tag.contains("type=\"audio/") || tag.contains("type='audio/") { sawAudio = true }
            searchRange = close.upperBound..<xml.endIndex
        }
        return sawAudio
    }
}

/// URL checks used by validation.
enum URLRules {
    /// An absolute `http`/`https` URL with a host. Macros (`${…}`, `[…]`) are tolerated: they are expanded before sending.
    static func isAbsoluteHTTPURL(_ text: String) -> Bool {
        guard let scheme = scheme(of: text), scheme == "http" || scheme == "https" else { return false }
        let afterScheme = text.dropFirst(scheme.count + 3)
        let host = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return !host.isEmpty && !host.contains(where: \.isWhitespace)
    }

    static func isHTTPS(_ text: String) -> Bool {
        scheme(of: text) == "https"
    }

    static func isHTTP(_ text: String) -> Bool {
        scheme(of: text) == "http"
    }

    /// Lower-cased scheme when the text starts with `scheme://`.
    static func scheme(of text: String) -> String? {
        guard let separator = text.range(of: "://") else { return nil }
        let scheme = text[..<separator.lowerBound]
        guard let first = scheme.first, first.isLetter, scheme.count <= 32,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }) else { return nil }
        return scheme.lowercased()
    }
}
