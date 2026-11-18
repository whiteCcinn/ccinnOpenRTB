import Foundation

/// VAST 2.0 – 4.2 parser (design D6). Owner: kit-vast.
///
/// Two steps: `VASTXMLReader` turns the text into an element tree defensively (size, depth and element caps; no DTD, so
/// no entity expansion; namespace prefixes stripped; CDATA kept), then `VASTDecoder` maps the tree to `VASTDocument` and
/// validates it against the declared version. Parsing never fails on content: a malformed value becomes an issue.
public enum VASTParser {
    public static func parse(_ xml: String) -> (document: VASTDocument?, issues: [ValidationIssue]) {
        parse(xml, requireSecure: false)
    }

    /// `requireSecure` (`imp.secure = 1`) turns non-HTTPS URLs from notes into warnings.
    public static func parse(_ xml: String, requireSecure: Bool) -> (document: VASTDocument?, issues: [ValidationIssue]) {
        switch outcome(of: xml, requireSecure: requireSecure) {
        case let .document(document, issues, _): (document, issues)
        case let .notXML(issues), let .notVAST(issues): (nil, issues)
        }
    }

    /// What a body turned out to be; the resolver maps it to a VAST error code (100 / 101).
    enum Outcome: Sendable {
        /// The document, its issues, and the elements carrying OpenRTB `${…}` macros.
        case document(VASTDocument, [ValidationIssue], [VASTMacroSite])
        /// Not well-formed XML, or rejected by the reader's limits (VAST error 100).
        case notXML([ValidationIssue])
        /// XML whose root is not `<VAST>` (VAST error 101).
        case notVAST([ValidationIssue])
    }

    static func outcome(of xml: String, requireSecure: Bool) -> Outcome {
        switch VASTXMLReader.read(xml) {
        case let .failure(failure):
            return .notXML([ValidationIssue(.error, code: failure.issueCode, message: failure.message + " (VAST error 100)", path: "VAST")])
        case let .success(root):
            var decoder = VASTDecoder(requireSecure: requireSecure)
            guard let document = decoder.decode(root: root) else { return .notVAST(decoder.issues) }
            return .document(document, decoder.issues, decoder.openRTBMacroSites)
        }
    }
}

extension VASTXMLReader.Failure {
    var issueCode: String {
        switch self {
        case .empty: "vast.xml.empty"
        case .tooLarge: "vast.xml.tooLarge"
        case .doctypeNotAllowed, .entityDeclarationNotAllowed: "vast.xml.dtd"
        case .tooDeep, .tooManyElements, .tooMuchText: "vast.xml.limit"
        case .malformed: "vast.xml.malformed"
        }
    }
}
