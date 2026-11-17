import Foundation

/// Parses the right-hand panel (design D3). Owner: kit-openrtb.
///
/// Detection order:
/// 1. the root element is `<VAST` (after an XML declaration / comments) → VAST markup;
/// 2. a single `http(s)://` URL → VAST tag URL;
/// 3. JSON with `openrtb.response` → OpenRTB 3.0;
/// 4. JSON with `seatbid`, or `id` with `nbr` / `bidid` / `cur` → OpenRTB 2.x;
/// 5. JSON with `native`, `assets` or `link` → Native markup;
/// 6. other `<…>` → HTML markup.
///
/// Parsing is lenient: wrong types become issues, never failures. Native bids' validation issues are included in
/// `ParsedInput.issues`; VAST issues come from `ResolvedVAST.issues` after resolution.
public enum InputParser {
    /// Detects what `text` is and parses it; `request` is the optional bid request JSON (OpenRTB 2.x or 3.0).
    public static func parse(_ text: String, request: String? = nil) -> ParsedInput {
        var requestInfo: BidRequestInfo?
        var requestIssues: [ValidationIssue] = []
        if let request, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            (requestInfo, requestIssues) = BidRequestReader.read(request)
        }
        var parsed = parseResponse(text, request: requestInfo)
        parsed.request = requestInfo?.summary
        parsed.issues.append(contentsOf: requestIssues)
        return parsed
    }

    static func parseResponse(_ text: String, request: BidRequestInfo?) -> ParsedInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ParsedInput(kind: .empty) }
        if MarkupSniffer.isVASTDocument(trimmed) { return bareVAST(.xml(trimmed), kind: .vastMarkup, xml: trimmed, request: request) }
        if MarkupSniffer.isHTTPURL(trimmed) { return bareVAST(.url(trimmed), kind: .vastURL, xml: nil, request: request) }

        if trimmed.first == "{" || trimmed.first == "[" {
            let value: JSONValue
            do {
                value = try JSONValue.parse(trimmed)
            } catch {
                let reason = "Invalid JSON: \(error)"
                return ParsedInput(kind: .invalid(reason), issues: [ValidationIssue(.error, code: "input.json.invalid", message: reason, path: "")])
            }
            return parseJSON(value, text: trimmed, request: request)
        }
        if trimmed.first == "<" { return bareHTML(trimmed, request: request) }
        let reason = "Not an OpenRTB bid response, Native JSON, VAST XML, a VAST URL or HTML markup."
        return ParsedInput(kind: .invalid(reason), issues: [ValidationIssue(.error, code: "input.unrecognized", message: reason, path: "")])
    }

    private static func parseJSON(_ value: JSONValue, text: String, request: BidRequestInfo?) -> ParsedInput {
        guard case let .object(members) = value else {
            let reason = "The JSON is not an object."
            return ParsedInput(kind: .invalid(reason), issues: [ValidationIssue(.error, code: "input.unrecognized", message: reason, path: "")])
        }
        var log = IssueLog()
        let root = JSONObjectReader(members, at: .root, domain: "openrtb")
        if case let .object(envelopeMembers)? = root.raw("openrtb") {
            let envelope = JSONObjectReader(envelopeMembers, at: JSONPointer.root.appending("openrtb"), domain: "openrtb")
            if let response = envelope.object("response", log: &log) {
                var decoder = OpenRTB3Decoder(request: request)
                return decoder.decode(envelope: envelope, response: response)
            }
            if envelope.has("request") { return invalid("This is an OpenRTB 3.0 bid request: paste it in the Request field.") }
        }
        if root.has("imp") { return invalid("This is an OpenRTB 2.x bid request: paste it in the Request field.") }
        let hasID = root.has("id")
        if root.has("seatbid") || (hasID && (root.has("nbr") || root.has("bidid") || root.has("cur"))) {
            var decoder = OpenRTB2Decoder(request: request)
            return decoder.decode(root)
        }
        if MarkupSniffer.isNativeObject(value) { return bareNative(text, request: request) }
        return invalid("The JSON is neither an OpenRTB bid response nor Native markup.")
    }

    private static func invalid(_ reason: String) -> ParsedInput {
        ParsedInput(kind: .invalid(reason), issues: [ValidationIssue(.error, code: "input.unrecognized", message: reason, path: "")])
    }

    // MARK: Bare markup

    /// The request impression a bare markup is shown in: the only one, or the first offering `format`.
    private static func impression(for format: AdFormat, in request: BidRequestInfo?) -> BidRequestSummary.Impression? {
        guard let impressions = request?.summary.impressions else { return nil }
        return impressions.first { $0.formats.contains(format) } ?? (impressions.count == 1 ? impressions.first : nil)
    }

    private static func bareCandidate(format: AdFormat, markup: AdMarkup, request: BidRequestInfo?) -> AdCandidate {
        let impression = impression(for: format, in: request)
        return AdCandidate(id: "0.0", bidID: "", impID: impression?.id, price: 0, currency: request?.summary.currencies.first ?? "USD",
                           size: impression?.size, format: format, markup: markup)
    }

    private static func bareVAST(_ source: VASTSource, kind: InputKind, xml: String?, request: BidRequestInfo?) -> ParsedInput {
        let audioOnly = xml.map(MarkupSniffer.vastLooksAudioOnly) ?? false
        let format: AdFormat = audioOnly ? .audio : .video
        return ParsedInput(kind: kind, candidates: [bareCandidate(format: format, markup: .vast(source), request: request)])
    }

    private static func bareHTML(_ html: String, request: BidRequestInfo?) -> ParsedInput {
        ParsedInput(kind: .htmlMarkup, candidates: [bareCandidate(format: .banner, markup: .html(html), request: request)])
    }

    private static func bareNative(_ json: String, request: BidRequestInfo?) -> ParsedInput {
        let candidate = bareCandidate(format: .native, markup: .native(json), request: request)
        var log = IssueLog()
        let impression = impression(for: .native, in: request)
        ResponseChecks.nativeMarkup(json, impression: impression, at: .root, log: &log)
        return ParsedInput(kind: .nativeMarkup, candidates: [candidate], issues: log.issues)
    }
}
