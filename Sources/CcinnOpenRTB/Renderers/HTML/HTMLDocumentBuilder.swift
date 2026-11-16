import Foundation

/// Turns an HTML `adm` into the document the web view loads.
enum HTMLDocumentBuilder {
    /// Stops WebKit from resolving host names of links the creative contains (DNS leaves the machine even when HTTP is blocked).
    static let dnsPrefetchOff = #"<meta http-equiv="x-dns-prefetch-control" content="off">"#

    /// A fragment is wrapped in a minimal document (viewport meta, zero margins); a full document gets only the DNS-prefetch
    /// switch, inserted as the first element of its `<head>` (or created right after `<html>`).
    static func document(for adm: String) -> String {
        guard isFullDocument(adm) else {
            return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width, initial-scale=1">\
            \(dnsPrefetchOff)\
            <style>html,body{margin:0;padding:0;}</style></head>
            <body>\(adm)</body></html>
            """
        }
        if let head = adm.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return adm.replacingCharacters(in: head.upperBound..<head.upperBound, with: dnsPrefetchOff)
        }
        if let html = adm.range(of: #"<html(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return adm.replacingCharacters(in: html.upperBound..<html.upperBound, with: "<head>\(dnsPrefetchOff)</head>")
        }
        return dnsPrefetchOff + adm
    }

    static func isFullDocument(_ adm: String) -> Bool {
        let lowered = adm.lowercased()
        return lowered.contains("<html") || lowered.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!doctype")
    }
}
