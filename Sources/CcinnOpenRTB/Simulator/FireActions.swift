import RTBKit

/// The Fire menu: lifecycle events the user can trigger by hand for the ad on the device (pure).
struct FireAction: Identifiable, Hashable {
    enum Kind: String, Hashable { case impression, viewability, click, close }

    var title: String
    var event: AdLifecycleEvent
    var kind: Kind
    var id: String { title }
}

/// A group of actions: the whole ad, or one pod ad.
struct FireSection: Identifiable, Hashable {
    var title: String?
    var actions: [FireAction]
    var id: String { title ?? "ad" }
}

enum FireActions {
    static func sections(for ad: PreparedAd?) -> [FireSection] {
        guard let ad else { return [] }
        switch ad.candidate.markup {
        case .vast:
            let vast = ad.vast
            let count = max(1, vast?.ads.count ?? 1)
            return (0..<count).map { index in
                let companions = vast?.ads[safe: index]?.inline.creatives.flatMap(\.companions).count ?? 0
                return FireSection(title: count > 1 ? "Ad \(index + 1) of \(count)" : nil, actions: vastActions(adIndex: index, companions: companions))
            } + [FireSection(title: count > 1 ? "Whole ad" : "Ad", actions: [
                FireAction(title: "Rendered (billing, first frame)", event: .rendered, kind: .impression),
                FireAction(title: "Close", event: .closed, kind: .close),
            ])]
        case .native:
            var actions = displayActions(includesVideo: ad.native?.assets.contains { if case .video = $0.content { true } else { false } } ?? false)
            for asset in ad.native?.assets ?? [] where asset.link != nil {
                actions.append(FireAction(title: "Click asset \(asset.id)", event: .click(assetID: asset.id), kind: .click))
            }
            return [FireSection(title: nil, actions: actions)]
        case .html, .image:
            return [FireSection(title: nil, actions: displayActions(includesVideo: false))]
        case .none:
            return []
        }
    }

    private static func displayActions(includesVideo: Bool) -> [FireAction] {
        var actions = [
            FireAction(title: "Impression (rendered)", event: .rendered, kind: .impression),
            FireAction(title: "Viewable · MRC 50%", event: .viewable(.mrc50), kind: .viewability),
            FireAction(title: "Viewable · MRC 100%", event: .viewable(.mrc100), kind: .viewability),
        ]
        if includesVideo { actions.append(FireAction(title: "Viewable · video 50%", event: .viewable(.video50), kind: .viewability)) }
        actions += [
            FireAction(title: "Click", event: .click(assetID: nil), kind: .click),
            FireAction(title: "Close", event: .closed, kind: .close),
        ]
        return actions
    }

    private static func vastActions(adIndex: Int, companions: Int) -> [FireAction] {
        let suffix = " · ad \(adIndex + 1)"
        var actions = [
            FireAction(title: "Impression (creativeView)" + suffix, event: .video(.creativeView, adIndex: adIndex), kind: .impression),
            FireAction(title: "Viewable" + suffix, event: .videoViewability(.viewable, adIndex: adIndex), kind: .viewability),
            FireAction(title: "Not viewable" + suffix, event: .videoViewability(.notViewable, adIndex: adIndex), kind: .viewability),
            FireAction(title: "View undetermined" + suffix, event: .videoViewability(.undetermined, adIndex: adIndex), kind: .viewability),
            FireAction(title: "Click" + suffix, event: .videoClick(adIndex: adIndex), kind: .click),
        ]
        for companion in 0..<companions {
            actions.append(FireAction(title: "Companion \(companion + 1) view" + suffix,
                                      event: .companionView(adIndex: adIndex, companionIndex: companion), kind: .impression))
            actions.append(FireAction(title: "Companion \(companion + 1) click" + suffix,
                                      event: .companionClick(adIndex: adIndex, companionIndex: companion), kind: .click))
        }
        return actions
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
