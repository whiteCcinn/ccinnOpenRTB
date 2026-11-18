import Foundation
import RTBKit

/// One row of the Inspector outline.
struct InspectorNode: Identifiable, Hashable, Sendable {
    /// Unique among siblings and stable across rebuilds (a path of titles), so expansion survives edits.
    var id: String
    var title: String
    var detail: String?
    var symbol: String
    var children: [InspectorNode]?

    init(_ title: String, detail: String? = nil, symbol: String = "circle.fill", id: String? = nil, children: [InspectorNode]? = nil) {
        self.id = id ?? title
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.children = children.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The Inspector's outline of one bid (pure): bid → markup → Native assets / VAST chain → creatives → trackers.
enum InspectorTree {
    static func build(candidate: AdCandidate, native: NativeAd?, vastDocument: VASTDocument?, resolved: ResolvedVAST?) -> [InspectorNode] {
        var nodes = [bidNode(candidate), auctionNode(candidate)].compactMap { $0 }
        if let native { nodes.append(nativeNode(native)) }
        if let resolved {
            nodes.append(resolvedNode(resolved))
        } else if let vastDocument {
            nodes.append(documentNode(vastDocument, id: "vast", title: "VAST \(vastDocument.version ?? "")".trimmingCharacters(in: .whitespaces)))
        }
        return uniquified(nodes, parent: "")
    }

    // MARK: Bid

    private static func bidNode(_ candidate: AdCandidate) -> InspectorNode {
        var fields: [InspectorNode] = [
            field("bid.id", candidate.bidID),
            field("impid", candidate.impID),
            field("seat", candidate.seat),
            field("price", "\(InputSummary.price(candidate.price)) \(candidate.currency)"),
            field("dealid", candidate.dealID),
            field("adid", candidate.adID),
            field("crid", candidate.creativeID),
            field("cid", candidate.campaignID),
            field("adomain", candidate.advertiserDomains.isEmpty ? nil : candidate.advertiserDomains.joined(separator: ", ")),
            field("bundle", candidate.bundle),
            field("size", candidate.size.map { "\($0.width)×\($0.height)" }),
            field("format", InputSummary.formatTitle(candidate.format) + (candidate.markupType.map { " (mtype \($0))" } ?? "")),
            field("exp", candidate.expirySeconds.map { "\($0) s" }),
        ].compactMap { $0 }
        fields.append(InspectorNode("markup", detail: markupSummary(candidate), symbol: "doc.text"))
        if let markupURL = candidate.markupURL { fields.append(InspectorNode("display.curl", detail: markupURL, symbol: "link")) }
        if !candidate.customMacros.isEmpty {
            fields.append(InspectorNode("bid.macro", detail: "\(candidate.customMacros.count)", symbol: "curlybraces",
                                        children: candidate.customMacros.sorted { $0.key < $1.key }.map {
                                            InspectorNode($0.key, detail: $0.value, symbol: "curlybraces")
                                        }))
        }
        return InspectorNode("Bid \(candidate.id)", detail: InputSummary.title(of: candidate), symbol: "dollarsign.circle", id: "bid",
                             children: fields)
    }

    static func markupSummary(_ candidate: AdCandidate) -> String {
        switch candidate.markup {
        case let .html(html): "HTML · \(byteCount(html))"
        case let .image(banner): "Image banner · \(banner.imageURL)"
        case let .native(json): "Native JSON · \(byteCount(json))"
        case let .vast(.xml(xml)): "VAST XML · \(byteCount(xml))"
        case let .vast(.url(url)): "VAST tag · \(url)"
        case .none: candidate.markupURL != nil ? "By reference (display.curl)" : "Delivered by the win notice (nurl)"
        }
    }

    private static func auctionNode(_ candidate: AdCandidate) -> InspectorNode? {
        var children = [
            candidate.winURL.map { InspectorNode("win (nurl / purl)", detail: $0, symbol: "trophy") },
            candidate.billingURL.map { InspectorNode("billing (burl)", detail: $0, symbol: "dollarsign.circle") },
            candidate.lossURL.map { InspectorNode("loss (lurl)", detail: $0, symbol: "xmark.circle") },
        ].compactMap { $0 }
        for (index, event) in candidate.adcomEvents.enumerated() {
            let method = event.method == 2 ? "JavaScript" : "image"
            children.append(InspectorNode("AdCOM event \(event.type) · \(adcomEventName(event.type))", detail: (event.url ?? event.script).map { "\(method) · \($0)" },
                                          symbol: "eye", id: "adcom-\(index)"))
        }
        guard !children.isEmpty else { return nil }
        return InspectorNode("Auction notices and events", detail: "\(children.count)", symbol: "bell", id: "auction", children: children)
    }

    /// AdCOM 1.0 event types.
    static func adcomEventName(_ type: Int) -> String {
        switch type {
        case 1: "loaded"
        case 2: "impression"
        case 3: "viewable MRC 50"
        case 4: "viewable MRC 100"
        case 5: "viewable video 50"
        default: type >= 500 ? "vendor-specific" : "unknown"
        }
    }

    // MARK: Native

    private static func nativeNode(_ native: NativeAd) -> InspectorNode {
        var children = native.assets.map(assetNode)
        children.append(InspectorNode("link", detail: native.link.url, symbol: "link",
                                      children: native.link.clickTrackers.map { InspectorNode($0, symbol: "cursorarrow.click") }))
        children += native.impressionTrackers.enumerated().map {
            InspectorNode("imptracker", detail: $0.element, symbol: "eye", id: "imp-\($0.offset)")
        }
        children += native.eventTrackers.enumerated().map {
            InspectorNode("eventtracker \($0.element.event) · \(nativeEventName($0.element.event))",
                          detail: ($0.element.method == 2 ? "JavaScript · " : "image · ") + $0.element.url, symbol: "eye.circle", id: "evt-\($0.offset)")
        }
        if let script = native.jsTracker { children.append(InspectorNode("jstracker", detail: script, symbol: "curlybraces")) }
        if let privacy = native.privacyURL { children.append(InspectorNode("privacy", detail: privacy, symbol: "hand.raised")) }
        if let url = native.assetsURL { children.append(InspectorNode("assetsurl", detail: url, symbol: "arrow.down.doc")) }
        if let url = native.dcoURL { children.append(InspectorNode("dcourl", detail: url, symbol: "arrow.down.doc")) }
        return InspectorNode("Native \(native.version ?? "")".trimmingCharacters(in: .whitespaces),
                             detail: "\(native.assets.count) assets" + (native.wrapped ? " · wrapped" : ""), symbol: "rectangle.grid.1x2",
                             id: "native", children: children)
    }

    private static func assetNode(_ asset: NativeAsset) -> InspectorNode {
        let (kind, detail): (String, String) = switch asset.content {
        case let .title(text): ("title", text)
        case let .image(url, width, height, type):
            ("image" + (type.map { " (\(imageTypeName($0)))" } ?? ""), [width.flatMap { w in height.map { "\(w)×\($0)" } }, url].compactMap { $0 }
                .joined(separator: " · "))
        case let .video(tag): ("video", "VAST tag · \(byteCount(tag))")
        case let .data(value, label, type): ("data" + (type.map { " (\(String(describing: $0)))" } ?? ""), [label, value].compactMap { $0 }
                .joined(separator: ": "))
        }
        let source = asset.typeSource == .response ? "" : " · type from \(asset.typeSource.rawValue)"
        return InspectorNode("asset \(asset.id) · \(kind)" + (asset.required ? " · required" : "") + source, detail: detail, symbol: "square.on.square",
                             id: "asset-\(asset.id)",
                             children: asset.link.map { link in
                                 [InspectorNode("link", detail: link.url, symbol: "link",
                                                children: link.clickTrackers.map { InspectorNode($0, symbol: "cursorarrow.click") })]
                             })
    }

    private static func imageTypeName(_ type: NativeImageType) -> String {
        switch type {
        case .icon: "icon"
        case .logo: "logo"
        case .main: "main"
        }
    }

    /// Native 1.2 event types.
    static func nativeEventName(_ type: Int) -> String {
        switch type {
        case 1: "impression"
        case 2: "viewable MRC 50"
        case 3: "viewable MRC 100"
        case 4: "viewable video 50"
        default: type >= 500 ? "exchange-specific" : "unknown"
        }
    }

    // MARK: VAST

    private static func resolvedNode(_ vast: ResolvedVAST) -> InspectorNode {
        let chain = vast.chain.enumerated().map { index, hop in
            InspectorNode("hop \(index + 1) · " + (hop.url == nil ? "in the bid" : "fetched"),
                          detail: [hop.url, hop.error.map { "error \($0.rawValue) \($0.title)" }].compactMap { $0 }.joined(separator: " · "),
                          symbol: hop.error == nil ? "arrow.down.circle" : "exclamationmark.triangle", id: "hop-\(index)",
                          children: hop.document.map { [documentNode($0, id: "doc", title: "VAST \($0.version ?? "")")] })
        }
        var children = [InspectorNode("Wrapper chain", detail: "\(vast.chain.count) document(s)", symbol: "link", id: "chain", children: chain)]
        children += vast.ads.enumerated().map { index, ad in
            var rows = [inlineNode(ad.inline, id: "inline")]
            rows += ad.impressions.enumerated().map { InspectorNode("Impression", detail: $0.element, symbol: "eye", id: "imp-\($0.offset)") }
            rows += ad.trackingEvents.enumerated().map {
                InspectorNode("Tracking \($0.element.event.label)", detail: $0.element.url, symbol: "play.circle", id: "trk-\($0.offset)")
            }
            rows += ad.clickTrackings.enumerated().map { InspectorNode("ClickTracking", detail: $0.element, symbol: "cursorarrow.click", id: "clk-\($0.offset)") }
            rows += ad.errors.enumerated().map { InspectorNode("Error", detail: $0.element, symbol: "exclamationmark.triangle", id: "err-\($0.offset)") }
            let viewable = ad.viewableImpression.viewable.count + ad.viewableImpression.notViewable.count + ad.viewableImpression.viewUndetermined.count
            if viewable > 0 { rows.append(InspectorNode("ViewableImpression", detail: "\(viewable) URL(s)", symbol: "eye.circle")) }
            rows += ad.verifications.enumerated().map {
                InspectorNode("Verification \($0.element.vendor ?? "")", detail: $0.element.javaScriptResource, symbol: "checkmark.seal", id: "ver-\($0.offset)")
            }
            return InspectorNode("Ad \(index + 1)" + (ad.sequence.map { " · sequence \($0)" } ?? ""),
                                 detail: [ad.inline.adSystem, ad.inline.adTitle].compactMap { $0 }.joined(separator: " · "), symbol: "film",
                                 id: "ad-\(index)", children: rows)
        }
        children += vast.adFailures.enumerated().map {
            InspectorNode("Failed slot · error \($0.element.code.rawValue)", detail: $0.element.code.title, symbol: "exclamationmark.triangle",
                          id: "fail-\($0.offset)")
        }
        let failure = vast.failure.map { " · error \($0.rawValue) \($0.title)" } ?? ""
        return InspectorNode("VAST (resolved)", detail: "\(vast.ads.count) ad(s)" + failure, symbol: "play.rectangle", id: "vast", children: children)
    }

    private static func documentNode(_ document: VASTDocument, id: String, title: String) -> InspectorNode {
        let ads = document.ads.enumerated().map { index, ad -> InspectorNode in
            switch ad.body {
            case let .inline(inline):
                return inlineNode(inline, id: "ad-\(index)", sequence: ad.sequence)
            case let .wrapper(wrapper):
                return InspectorNode("Wrapper" + (ad.sequence.map { " · sequence \($0)" } ?? ""), detail: wrapper.adTagURI, symbol: "arrow.turn.down.right",
                                     id: "ad-\(index)",
                                     children: wrapper.impressions.enumerated().map {
                                         InspectorNode("Impression", detail: $0.element, symbol: "eye", id: "imp-\($0.offset)")
                                     })
            }
        }
        return InspectorNode(title, detail: "\(document.ads.count) ad(s)", symbol: "play.rectangle", id: id, children: ads)
    }

    private static func inlineNode(_ inline: VASTInline, id: String, sequence: Int? = nil) -> InspectorNode {
        let creatives = inline.creatives.enumerated().map { index, creative -> InspectorNode in
            var rows: [InspectorNode] = []
            if let linear = creative.linear {
                rows += linear.mediaFiles.enumerated().map { offset, file in
                    let size = file.width.flatMap { w in file.height.map { "\(w)×\($0)" } }
                    let info = [file.type, size, file.bitrate.map { "\($0) kbps" }, file.apiFramework].compactMap { $0 }.joined(separator: " · ")
                    return InspectorNode("MediaFile · \(info)", detail: file.url, symbol: "film.stack", id: "media-\(offset)")
                }
                if let click = linear.clickThrough { rows.append(InspectorNode("ClickThrough", detail: click, symbol: "arrow.up.forward.app")) }
            }
            rows += creative.companions.enumerated().map { offset, companion in
                InspectorNode("Companion \(companion.width ?? 0)×\(companion.height ?? 0)", detail: companion.clickThrough, symbol: "rectangle.on.rectangle",
                              id: "companion-\(offset)")
            }
            let kind = creative.linear.map { linear in "Linear" + (linear.duration.map { " · \(Format.duration(seconds: $0))" } ?? "") }
                ?? (creative.hasNonLinear ? "NonLinear" : "Companions")
            let skip = creative.linear?.skipOffset.map { _ in " · skippable" } ?? ""
            return InspectorNode("Creative \(index + 1) · \(kind)\(skip)", symbol: "rectangle.stack", id: "creative-\(index)", children: rows)
        }
        return InspectorNode("InLine" + (sequence.map { " · sequence \($0)" } ?? ""),
                             detail: [inline.adSystem, inline.adTitle].compactMap { $0 }.joined(separator: " · "), symbol: "film", id: id,
                             children: creatives)
    }

    // MARK: Helpers

    private static func field(_ name: String, _ value: String?) -> InspectorNode? {
        guard let value, !value.isEmpty else { return nil }
        return InspectorNode(name, detail: value, symbol: "smallcircle.filled.circle")
    }

    static func byteCount(_ text: String) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
    }

    /// Makes every id unique and path-based (`bid/price`), so `List` never sees duplicates.
    private static func uniquified(_ nodes: [InspectorNode], parent: String) -> [InspectorNode] {
        var seen: [String: Int] = [:]
        return nodes.map { node in
            var node = node
            let count = seen[node.id, default: 0]
            seen[node.id] = count + 1
            node.id = parent + "/" + node.id + (count > 0 ? "#\(count)" : "")
            node.children = node.children.map { uniquified($0, parent: node.id) }
            return node
        }
    }
}
