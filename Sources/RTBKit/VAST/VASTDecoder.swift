import Foundation

/// Maps a `VASTXMLElement` tree to a `VASTDocument` and validates it against the declared version.
///
/// Decoding is lenient: a malformed value becomes an issue and the field is left empty, and unknown elements are
/// ignored. Every issue names the element it is about, as a path with 1-based indices for repeatable elements
/// (`VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/MediaFiles/MediaFile[2]`).
struct VASTDecoder {
    /// Where a creative lives: InLine creatives are played; Wrapper creatives only carry trackers.
    private enum Context {
        case inline, wrapper
    }

    private(set) var issues: [ValidationIssue] = []
    /// The declared version when it is one the simulator knows; `nil` when missing or invalid.
    private(set) var version: VASTSpecVersion?
    /// `imp.secure = 1`: a non-HTTPS URL is a warning instead of a note.
    private let requireSecure: Bool

    init(requireSecure: Bool = false) {
        self.requireSecure = requireSecure
    }

    /// Severity for a missing attribute the XSD requires: an error from VAST 3.0 on, a warning for 2.0 and undeclared
    /// versions (players accept those in practice).
    private var requiredAttributeSeverity: ValidationIssue.Severity {
        (version ?? .v2_0) >= .v3_0 ? .error : .warning
    }

    // MARK: - Document

    mutating func decode(root: VASTXMLElement) -> VASTDocument? {
        let path = "VAST"
        guard root.name.caseInsensitiveCompare("VAST") == .orderedSame else {
            report(.error, "vast.root.invalid", "The root element is <\(root.name)>; a VAST document starts with <VAST>.", root.name)
            return nil
        }
        if root.name != "VAST" {
            report(.warning, "vast.root.case", "Element names are case-sensitive: <\(root.name)> should be <VAST>.", path)
        }

        let declaredVersion = root.attribute("version")?.trimmingCharacters(in: .whitespacesAndNewlines)
        interpretVersion(declaredVersion, at: path)
        checkChildren(of: root, at: path)

        let errorElements = root.children(named: "Error")
        if !errorElements.isEmpty { checkIntroduced("VAST/Error", at: path + "/Error") }
        let errors = urls(errorElements, at: path + "/Error", role: .tracker)

        var ads: [VASTAd] = []
        for (index, element) in root.children(named: "Ad").enumerated() {
            if let ad = decodeAd(element, at: path + "/Ad[\(index + 1)]") { ads.append(ad) }
        }
        checkPod(ads, at: path)
        if ads.isEmpty {
            let detail = errors.isEmpty ? "and no <Error> URL" : "; its root <Error> URLs are fired with error 303"
            report(.info, "vast.noAd", "The document has no usable <Ad> (a no-ad response) \(detail).", path)
        }
        return VASTDocument(version: declaredVersion, ads: ads, errors: errors)
    }

    private mutating func interpretVersion(_ declared: String?, at path: String) {
        guard let declared, !declared.isEmpty else {
            report(.warning, "vast.version.missing", "<VAST> has no version attribute; it is parsed leniently, as the latest version (4.2).",
                   path + "@version")
            return
        }
        switch VASTSpecVersion.interpret(declared) {
        case let .supported(known):
            version = known
        case let .unsupported(closest):
            version = closest
            report(.warning, "vast.version.unsupported",
                   "VAST \(declared) is not one of 2.0, 3.0, 4.0, 4.1, 4.2 (VAST error 102); it is parsed as \(closest.rawValue), best effort.",
                   path + "@version")
        case .invalid:
            report(.warning, "vast.version.invalid", "\"\(declared)\" is not a VAST version number; it is parsed leniently, as the latest version (4.2).",
                   path + "@version")
        }
    }

    /// Pod structure: duplicate `sequence` values, and what stand-alone ads next to a pod (the buffet) are used for.
    private mutating func checkPod(_ ads: [VASTAd], at path: String) {
        let sequences = ads.compactMap(\.sequence)
        let standAloneCount = ads.count - sequences.count
        var seen: Set<Int> = []
        for sequence in sequences where !seen.insert(sequence).inserted {
            report(.warning, "vast.pod.sequence.duplicate",
                   "Two ads in the pod have sequence=\"\(sequence)\"; they play in document order.", path + "/Ad")
        }
        if !sequences.isEmpty, standAloneCount > 0 {
            report(.info, "vast.pod.buffet",
                   "\(standAloneCount) stand-alone ad(s) next to the pod form the ad buffet: they play only if no pod ad can be played, or in place of a wrapper slot with fallbackOnNoAd=\"true\" that returned no ad.",
                   path + "/Ad")
        } else if sequences.isEmpty, standAloneCount > 1 {
            report(.info, "vast.ads.standAlone.multiple",
                   "The document has \(standAloneCount) stand-alone ads: the first one that resolves plays, the others are fallbacks.", path + "/Ad")
        }
    }

    // MARK: - Ad

    private mutating func decodeAd(_ element: VASTXMLElement, at path: String) -> VASTAd? {
        checkChildren(of: element, at: path)
        let sequence = sequenceAttribute(of: element, feature: "Ad@sequence", at: path)
        let adType = decodeAdType(of: element, at: path)

        let bodies = element.children.filter { $0.name == "InLine" || $0.name == "Wrapper" }
        guard let body = bodies.first else {
            report(.error, "vast.ad.body.missing", "<Ad> must contain an <InLine> or a <Wrapper>.", path)
            return nil
        }
        if bodies.count > 1 {
            report(.error, "vast.ad.body.multiple", "<Ad> must contain exactly one <InLine> or <Wrapper>; the first one is used.", path)
        }
        let id = nonEmpty(element.attribute("id"))
        if body.name == "InLine" {
            return VASTAd(id: id, sequence: sequence, body: .inline(decodeInline(body, at: path + "/InLine")), adType: adType)
        }
        return VASTAd(id: id, sequence: sequence, body: .wrapper(decodeWrapper(body, at: path + "/Wrapper")), adType: adType)
    }

    /// VAST 4.1 §3.3.2 `adType`: `video`, `audio` or `hybrid` (absent: assumed `video`). Kept as written, trimmed.
    private mutating func decodeAdType(of element: VASTXMLElement, at path: String) -> String? {
        guard let raw = element.attribute("adType") else { return nil }
        checkIntroduced("Ad@adType", at: path + "@adType")
        guard let adType = nonEmpty(raw) else {
            report(.warning, "vast.ad.adType.invalid", "adType is empty; it must be video, audio or hybrid (absent means video).", path + "@adType")
            return nil
        }
        if !VASTSpecRules.adTypes.contains(adType) {
            report(.warning, "vast.ad.adType.invalid", "adType=\"\(adType)\" must be video, audio or hybrid.", path + "@adType")
        }
        return adType
    }

    private mutating func sequenceAttribute(of element: VASTXMLElement, feature: String?, at path: String) -> Int? {
        guard let raw = element.attribute("sequence") else { return nil }
        if let feature { checkIntroduced(feature, at: path + "@sequence") }
        guard let value = integer(raw) else {
            report(.warning, "vast.attribute.sequence.invalid", "sequence=\"\(raw)\" is not an integer; it is ignored.", path + "@sequence")
            return nil
        }
        if value < 1 {
            report(.warning, "vast.attribute.sequence.invalid", "sequence must be a positive integer (got \(value)).", path + "@sequence")
        }
        return value
    }

    // MARK: - InLine

    private mutating func decodeInline(_ element: VASTXMLElement, at path: String) -> VASTInline {
        checkChildren(of: element, at: path)
        checkIntroducedChildren(of: element, at: path)

        let adSystem = nonEmpty(element.firstChild(named: "AdSystem")?.trimmedText)
        if adSystem == nil {
            report(.error, "vast.inline.adSystem.missing", "An InLine ad must name its <AdSystem>.", path + "/AdSystem")
        }
        let adTitle = nonEmpty(element.firstChild(named: "AdTitle")?.trimmedText)
        if adTitle == nil {
            report(.error, "vast.inline.adTitle.missing", "An InLine ad must have an <AdTitle>.", path + "/AdTitle")
        }
        let adServingID = nonEmpty(element.firstChild(named: "AdServingId")?.trimmedText)
        if let version, version >= .v4_1, adServingID == nil {
            report(.warning, "vast.inline.adServingId.missing", "VAST \(version.rawValue) requires <AdServingId> in an InLine ad.",
                   path + "/AdServingId")
        }
        let impressions = urls(element.children(named: "Impression"), at: path + "/Impression", role: .tracker)
        if impressions.isEmpty {
            report(.error, "vast.inline.impression.missing", "An InLine ad must have at least one non-empty <Impression> URL.",
                   path + "/Impression")
        }
        let errors = urls(element.children(named: "Error"), at: path + "/Error", role: .tracker)

        let creatives = decodeCreatives(element.firstChild(named: "Creatives"), at: path + "/Creatives", context: .inline)
        if creatives.isEmpty {
            report(.error, "vast.inline.creatives.missing", "An InLine ad must have <Creatives> with at least one <Creative>.",
                   path + "/Creatives")
        }

        return VASTInline(adSystem: adSystem, adTitle: adTitle, impressions: impressions, errors: errors, creatives: creatives,
                          viewableImpression: decodeViewableImpression(element.firstChild(named: "ViewableImpression"),
                                                                       at: path + "/ViewableImpression"),
                          verifications: decodeAllVerifications(of: element, at: path), adServingID: adServingID,
                          categories: decodeCategories(element.children(named: "Category"), at: path + "/Category"))
    }

    /// VAST 4.1 §3.4.5: "If category is used, the authority= attribute must be provided."
    private mutating func decodeCategories(_ elements: [VASTXMLElement], at path: String) -> [VASTCategory] {
        elements.enumerated().compactMap { index, element in
            let categoryPath = path + "[\(index + 1)]"
            guard let code = nonEmpty(element.trimmedText) else {
                report(.warning, "vast.inline.category.empty", "<Category> has no category code; it is ignored.", categoryPath)
                return nil
            }
            let authority = nonEmpty(element.attribute("authority"))
            if authority == nil {
                report(.warning, "vast.inline.category.authority.missing",
                       "<Category> \(code) has no authority attribute; it is required whenever a category is given.", categoryPath + "@authority")
            }
            return VASTCategory(code: code, authority: authority)
        }
    }

    // MARK: - Wrapper

    private mutating func decodeWrapper(_ element: VASTXMLElement, at path: String) -> VASTWrapper {
        checkChildren(of: element, at: path)
        checkIntroducedChildren(of: element, at: path)

        if nonEmpty(element.firstChild(named: "AdSystem")?.trimmedText) == nil {
            report(.warning, "vast.wrapper.adSystem.missing", "A Wrapper should name its <AdSystem>.", path + "/AdSystem")
        }
        var adTagURI = ""
        if let tagElement = element.firstChild(named: "VASTAdTagURI"), !tagElement.trimmedText.isEmpty {
            adTagURI = tagElement.trimmedText
            checkURL(adTagURI, role: .adTag, at: path + "/VASTAdTagURI")
        } else {
            report(.error, "vast.wrapper.adTagURI.missing", "A Wrapper must have a non-empty <VASTAdTagURI>; it cannot be followed (VAST error 300).",
                   path + "/VASTAdTagURI")
        }

        let impressions = urls(element.children(named: "Impression"), at: path + "/Impression", role: .tracker)
        if impressions.isEmpty {
            report(.warning, "vast.wrapper.impression.missing", "A Wrapper should have at least one <Impression> URL.", path + "/Impression")
        }
        let errors = urls(element.children(named: "Error"), at: path + "/Error", role: .tracker)
        let creatives = decodeCreatives(element.firstChild(named: "Creatives"), at: path + "/Creatives", context: .wrapper)

        return VASTWrapper(adTagURI: adTagURI, impressions: impressions, errors: errors, creatives: creatives,
                           viewableImpression: decodeViewableImpression(element.firstChild(named: "ViewableImpression"),
                                                                        at: path + "/ViewableImpression"),
                           verifications: decodeAllVerifications(of: element, at: path),
                           followAdditionalWrappers: boolAttribute("followAdditionalWrappers", of: element, default: true, at: path),
                           allowMultipleAds: boolAttribute("allowMultipleAds", of: element, default: false, at: path),
                           fallbackOnNoAd: boolAttribute("fallbackOnNoAd", of: element, default: false, at: path))
    }

    private mutating func boolAttribute(_ name: String, of element: VASTXMLElement, default defaultValue: Bool, at path: String) -> Bool {
        guard let raw = element.attribute(name) else { return defaultValue }
        checkIntroduced("Wrapper@" + name, at: path + "@" + name)
        guard let value = boolean(raw) else {
            report(.warning, "vast.attribute.boolean.invalid", "\(name)=\"\(raw)\" is not a boolean; the default (\(defaultValue)) is used.",
                   path + "@" + name)
            return defaultValue
        }
        return value
    }

    // MARK: - Creatives

    private mutating func decodeCreatives(_ element: VASTXMLElement?, at path: String, context: Context) -> [VASTCreative] {
        guard let element else { return [] }
        checkChildren(of: element, at: path)
        return element.children(named: "Creative").enumerated().map { index, creative in
            decodeCreative(creative, at: path + "/Creative[\(index + 1)]", context: context)
        }
    }

    private mutating func decodeCreative(_ element: VASTXMLElement, at path: String, context: Context) -> VASTCreative {
        checkChildren(of: element, at: path)
        checkIntroducedChildren(of: element, at: path)
        let sequence = sequenceAttribute(of: element, feature: nil, at: path)

        let linearElement = element.firstChild(named: "Linear")
        let companionAds = element.firstChild(named: "CompanionAds")
        let nonLinearAds = element.firstChild(named: "NonLinearAds")
        if linearElement == nil, companionAds == nil, nonLinearAds == nil {
            report(.warning, "vast.creative.empty", "<Creative> has no <Linear>, <CompanionAds> or <NonLinearAds>.", path)
        }
        if context == .inline, let version, version >= .v4_0, element.firstChild(named: "UniversalAdId") == nil {
            report(.warning, "vast.creative.universalAdId.missing", "VAST \(version.rawValue) requires <UniversalAdId> in every InLine <Creative>.",
                   path + "/UniversalAdId")
        }
        if nonLinearAds != nil {
            report(.info, "vast.nonLinear.notPlayed", "NonLinear creatives are shown as a note in the simulator, not played.",
                   path + "/NonLinearAds")
        }
        if element.children(named: "Linear").count > 1 {
            report(.warning, "vast.creative.linear.multiple", "<Creative> has more than one <Linear>; the first one is used.", path + "/Linear")
        }

        return VASTCreative(id: nonEmpty(element.attribute("id")), adID: nonEmpty(element.attribute("adId")), sequence: sequence,
                            linear: linearElement.map { decodeLinear($0, at: path + "/Linear", context: context) },
                            companions: decodeCompanions(companionAds, at: path + "/CompanionAds", context: context),
                            hasNonLinear: nonLinearAds != nil,
                            universalAdIDs: decodeUniversalAdIDs(element.children(named: "UniversalAdId"), at: path + "/UniversalAdId"))
    }

    /// VAST 4.1 §3.7.1: the content is the source of truth; VAST 4.0's `idValue` attribute (a duplicate of it, removed in
    /// 4.1) is used only when the content is empty; both default to "unknown". Several elements are allowed from VAST 4.2.
    private mutating func decodeUniversalAdIDs(_ elements: [VASTXMLElement], at path: String) -> [VASTUniversalAdID] {
        if elements.count > 1, let version, version < .v4_2 {
            report(.info, "vast.element.newerVersion",
                   "Several <UniversalAdId> elements in one creative were introduced in VAST 4.2, but the document declares \(version.rawValue).",
                   path + "[2]")
        }
        return elements.enumerated().map { index, element in
            let elementPath = elements.count > 1 ? path + "[\(index + 1)]" : path
            let registry = nonEmpty(element.attribute("idRegistry"))
            if registry == nil {
                report(.warning, "vast.universalAdId.idRegistry.missing",
                       "<UniversalAdId> must have an idRegistry attribute (use \"unknown\" when there is no registry).", elementPath + "@idRegistry")
            }
            return VASTUniversalAdID(registry: registry ?? "unknown",
                                     value: nonEmpty(element.trimmedText) ?? nonEmpty(element.attribute("idValue")) ?? "unknown")
        }
    }

    // MARK: - Linear

    private mutating func decodeLinear(_ element: VASTXMLElement, at path: String, context: Context) -> VASTLinear {
        checkChildren(of: element, at: path)
        checkIntroducedChildren(of: element, at: path)

        var skipOffset: VASTOffset?
        if let raw = element.attribute("skipoffset") {
            checkIntroduced("Linear@skipoffset", at: path + "@skipoffset")
            skipOffset = VASTTimeFormat.offset(from: raw)
            if skipOffset == nil {
                report(.warning, "vast.linear.skipoffset.invalid",
                       "skipoffset=\"\(raw)\" is not HH:MM:SS(.mmm) or n%; the ad is treated as not skippable.", path + "@skipoffset")
            }
        }

        let duration = decodeDuration(element.firstChild(named: "Duration"), at: path + "/Duration", context: context)
        if let skipOffset, let duration, skipOffset.seconds(inAdOf: duration) >= duration {
            report(.warning, "vast.linear.skipoffset.beyondDuration",
                   "skipoffset \(skipOffset.vastText) is not before the end of the \(VASTOffset.seconds(duration).vastText) ad: it can never be skipped.",
                   path + "@skipoffset")
        }
        let mediaFiles = decodeMediaFiles(element.firstChild(named: "MediaFiles"), at: path + "/MediaFiles", context: context)
        let trackingEvents = decodeTrackingEvents(element.firstChild(named: "TrackingEvents"), at: path + "/TrackingEvents",
                                                  duration: duration)

        var clickThrough: String?
        var clickTrackings: [String] = []
        var customClicks: [String] = []
        if let videoClicks = element.firstChild(named: "VideoClicks") {
            let clicksPath = path + "/VideoClicks"
            checkChildren(of: videoClicks, at: clicksPath)
            if let throughElement = videoClicks.firstChild(named: "ClickThrough") {
                if context == .wrapper {
                    report(.info, "vast.wrapper.clickThrough.ignored", "A Wrapper cannot set the ClickThrough; the InLine ad's is used.",
                           clicksPath + "/ClickThrough")
                } else {
                    clickThrough = url(throughElement, at: clicksPath + "/ClickThrough", role: .clickThrough)
                }
            }
            clickTrackings = urls(videoClicks.children(named: "ClickTracking"), at: clicksPath + "/ClickTracking", role: .tracker)
            customClicks = urls(videoClicks.children(named: "CustomClick"), at: clicksPath + "/CustomClick", role: .tracker)
        }

        if element.firstChild(named: "Icons") != nil {
            report(.info, "vast.icons.notRendered", "Icons (e.g. AdChoices) are parsed but not rendered by the simulator.", path + "/Icons")
        }

        return VASTLinear(duration: duration, skipOffset: skipOffset, mediaFiles: mediaFiles, trackingEvents: trackingEvents,
                          clickThrough: clickThrough, clickTrackings: clickTrackings, customClicks: customClicks,
                          adParameters: nonEmpty(element.firstChild(named: "AdParameters")?.trimmedText))
    }

    private mutating func decodeDuration(_ element: VASTXMLElement?, at path: String, context: Context) -> Double? {
        guard let element else {
            if context == .inline {
                report(.error, "vast.linear.duration.missing", "An InLine <Linear> must have a <Duration>.", path)
            }
            return nil
        }
        guard let seconds = VASTTimeFormat.seconds(from: element.text) else {
            report(context == .inline ? .error : .warning, "vast.linear.duration.invalid",
                   "<Duration> \"\(element.trimmedText)\" is not HH:MM:SS or HH:MM:SS.mmm.", path)
            return nil
        }
        return seconds
    }

    // MARK: - MediaFiles

    private mutating func decodeMediaFiles(_ element: VASTXMLElement?, at path: String, context: Context) -> [VASTMediaFile] {
        guard context == .inline else { return [] }
        guard let element else {
            report(.error, "vast.linear.mediaFiles.missing", "An InLine <Linear> must have <MediaFiles>.", path)
            return []
        }
        checkChildren(of: element, at: path)
        checkIntroducedChildren(of: element, at: path)

        let mediaElements = element.children(named: "MediaFile")
        if mediaElements.isEmpty {
            report(.error, "vast.linear.mediaFiles.missing", "<MediaFiles> must contain at least one <MediaFile>.", path + "/MediaFile")
        }
        var files: [VASTMediaFile] = []
        for (index, mediaElement) in mediaElements.enumerated() {
            if let file = decodeMediaFile(mediaElement, at: path + "/MediaFile[\(index + 1)]") { files.append(file) }
        }

        if element.firstChild(named: "Mezzanine") != nil {
            report(.info, "vast.mezzanine.notPlayed", "<Mezzanine> is the high-quality source for server-side transcoding; the player uses <MediaFile>.",
                   path + "/Mezzanine")
        }
        if element.firstChild(named: "InteractiveCreativeFile") != nil {
            report(.info, "vast.interactiveCreativeFile.notExecuted",
                   "<InteractiveCreativeFile> (e.g. SIMID) is not executed by the simulator; the <MediaFile> plays on its own.",
                   path + "/InteractiveCreativeFile")
        }
        if !files.isEmpty { checkPlayable(files, at: path) }
        return files
    }

    private mutating func decodeMediaFile(_ element: VASTXMLElement, at path: String) -> VASTMediaFile? {
        guard let url = url(element, at: path, role: .resource, emptyCode: "vast.mediaFile.url.missing", emptySeverity: .error) else {
            return nil
        }
        for attribute in ["minBitrate", "maxBitrate", "codec", "fileSize", "mediaType"] where element.attribute(attribute) != nil {
            checkIntroduced("MediaFile@" + attribute, at: path + "@" + attribute)
        }

        let type = nonEmpty(element.attribute("type")?.trimmingCharacters(in: .whitespaces))
        let isAudio = type?.lowercased().hasPrefix("audio/") ?? false
        let delivery = nonEmpty(element.attribute("delivery")?.trimmingCharacters(in: .whitespaces))
        if let delivery, !VASTSpecRules.deliveryValues.contains(delivery) {
            report(.warning, "vast.mediaFile.delivery.invalid", "delivery=\"\(delivery)\" must be \"progressive\" or \"streaming\".", path + "@delivery")
        }
        for (name, value) in [("delivery", delivery), ("type", type)] where value == nil {
            report(requiredAttributeSeverity, "vast.mediaFile.\(name).missing", "<MediaFile> must have a \(name) attribute.", path + "@" + name)
        }

        let width = integerAttribute("width", of: element, at: path)
        let height = integerAttribute("height", of: element, at: path)
        for (name, value) in [("width", width), ("height", height)] where value == nil && element.attribute(name) == nil {
            if isAudio {
                report(.info, "vast.mediaFile.\(name).missing", "The schema requires \(name) on every <MediaFile>; for audio, use 0.", path + "@" + name)
            } else {
                report(requiredAttributeSeverity, "vast.mediaFile.\(name).missing", "<MediaFile> must have a \(name) attribute.", path + "@" + name)
            }
        }

        return VASTMediaFile(url: url, delivery: delivery, type: type, width: width, height: height,
                             bitrate: integerAttribute("bitrate", of: element, at: path),
                             minBitrate: integerAttribute("minBitrate", of: element, at: path),
                             maxBitrate: integerAttribute("maxBitrate", of: element, at: path),
                             codec: nonEmpty(element.attribute("codec")), apiFramework: nonEmpty(element.attribute("apiFramework")),
                             scalable: booleanAttribute("scalable", of: element, at: path),
                             maintainAspectRatio: booleanAttribute("maintainAspectRatio", of: element, at: path))
    }

    /// Reports InLine media the simulator cannot play: VPAID only (error 901) or nothing AVPlayer supports (error 403).
    private mutating func checkPlayable(_ files: [VASTMediaFile], at path: String) {
        let choice = VASTMediaSelector.choose(files, playerWidth: 1280, playerHeight: 720)
        guard case let .unsupported(code) = choice else { return }
        if code == .vpaidError {
            report(.warning, "vast.mediaFiles.vpaidOnly",
                   "Every playable <MediaFile> is VPAID, which the simulator does not run; playback fails with VAST error 901.", path)
        } else {
            report(.warning, "vast.mediaFiles.unplayable",
                   "No <MediaFile> can be played by AVPlayer (MP4, HLS, QuickTime or audio); playback fails with VAST error 403.", path)
        }
    }

    // MARK: - Tracking

    /// - Parameters:
    ///   - duration: the linear ad's duration, to report `progress` offsets it never reaches.
    ///   - versionChecks: `false` inside `Extensions`, where VAST 3.0 documents carry VAST 4.1 structures on purpose.
    private mutating func decodeTrackingEvents(_ element: VASTXMLElement?, at path: String, verification: Bool = false, duration: Double? = nil,
                                               versionChecks: Bool = true) -> [VASTTracking] {
        guard let element else { return [] }
        checkChildren(of: element, at: path)
        var trackings: [VASTTracking] = []
        for (index, trackingElement) in element.children(named: "Tracking").enumerated() {
            let trackingPath = path + "/Tracking[\(index + 1)]"
            guard let rawName = nonEmpty(trackingElement.attribute("event")?.trimmingCharacters(in: .whitespaces)) else {
                report(.warning, "vast.tracking.event.missing", "<Tracking> has no event attribute; it is ignored.", trackingPath)
                continue
            }
            guard let event = trackingEvent(named: rawName, element: trackingElement, verification: verification, duration: duration,
                                            versionChecks: versionChecks, at: trackingPath),
                  let url = url(trackingElement, at: trackingPath, role: .tracker)
            else { continue }
            trackings.append(VASTTracking(event: event, url: url))
        }
        return trackings
    }

    private mutating func trackingEvent(named rawName: String, element: VASTXMLElement, verification: Bool, duration: Double?, versionChecks: Bool,
                                        at path: String) -> VASTEvent? {
        var name = rawName
        if let canonical = VASTSpecRules.canonicalEventNames[rawName.lowercased()], canonical != rawName {
            report(.warning, "vast.tracking.event.case", "Event names are case-sensitive: \"\(rawName)\" should be \"\(canonical)\".", path + "@event")
            name = canonical
        }

        if versionChecks, let introduced = VASTSpecRules.eventIntroducedIn[name], let version, version < introduced {
            report(.info, "vast.element.newerVersion",
                   "The \(name) event was introduced in VAST \(introduced.rawValue), but the document declares \(version.rawValue).", path + "@event")
        }
        if let replacement = VASTSpecRules.eventsReplacedInVAST4[name], let version, version >= .v4_0 {
            report(.info, "vast.tracking.event.deprecated", "VAST 4 replaced the \(name) event with \(replacement).", path + "@event")
        }

        if name == "progress" {
            guard let rawOffset = element.attribute("offset"), let offset = VASTTimeFormat.offset(from: rawOffset) else {
                let shown = element.attribute("offset").map { "offset=\"\($0)\"" } ?? "no offset"
                report(.warning, "vast.tracking.offset.invalid",
                       "A progress event needs offset=\"HH:MM:SS(.mmm)\" or \"n%\" (got \(shown)); it is ignored.", path + "@offset")
                return nil
            }
            if case let .seconds(seconds) = offset, let duration, seconds > duration {
                report(.warning, "vast.tracking.offset.beyondDuration",
                       "progress offset \(offset.vastText) is after the end of the \(VASTOffset.seconds(duration).vastText) ad; it never fires.",
                       path + "@offset")
            }
            return .progress(offset)
        }
        if let event = VASTSpecRules.eventsByName[name] { return event }
        if verification, name == VASTSpecRules.verificationNotExecuted { return .other(name) }
        report(.info, "vast.tracking.event.unknown", "Unknown tracking event \"\(name)\"; it is kept and fired only if the player reports it.",
               path + "@event")
        return .other(name)
    }

    // MARK: - Companions

    private mutating func decodeCompanions(_ element: VASTXMLElement?, at path: String, context: Context) -> [VASTCompanion] {
        guard let element else { return [] }
        checkChildren(of: element, at: path)
        return element.children(named: "Companion").enumerated().map { index, companion in
            decodeCompanion(companion, at: path + "/Companion[\(index + 1)]", context: context)
        }
    }

    /// A wrapper's companions carry only tracking (`creativeView`, CompanionClickTracking), so they need no resource.
    private mutating func decodeCompanion(_ element: VASTXMLElement, at path: String, context: Context) -> VASTCompanion {
        checkChildren(of: element, at: path)
        checkIntroducedChildren(of: element, at: path)

        let width = integerAttribute("width", of: element, at: path)
        let height = integerAttribute("height", of: element, at: path)
        for (name, value) in [("width", width), ("height", height)] where value == nil && element.attribute(name) == nil {
            report(.warning, "vast.companion.\(name).missing", "<Companion> must have a \(name) attribute.", path + "@" + name)
        }

        var resources: [VASTCompanion.Resource] = []
        var resourceIndex: [String: Int] = [:]
        for child in element.children where ["StaticResource", "IFrameResource", "HTMLResource"].contains(child.name) {
            resourceIndex[child.name, default: 0] += 1
            let childPath = path + "/\(child.name)[\(resourceIndex[child.name] ?? 1)]"
            switch child.name {
            case "StaticResource":
                if let url = url(child, at: childPath, role: .resource) {
                    resources.append(.staticResource(url: url, creativeType: nonEmpty(child.attribute("creativeType"))))
                }
            case "IFrameResource":
                if let url = url(child, at: childPath, role: .resource) { resources.append(.iframe(url: url)) }
            default:
                if let html = nonEmpty(child.trimmedText) {
                    resources.append(.html(html))
                } else {
                    report(.warning, "vast.companion.html.empty", "<HTMLResource> is empty.", childPath)
                }
            }
        }
        if resources.isEmpty, context == .inline {
            report(.warning, "vast.companion.resource.missing", "<Companion> needs a StaticResource, IFrameResource or HTMLResource.", path)
        }

        return VASTCompanion(id: nonEmpty(element.attribute("id")), width: width, height: height, resources: resources,
                             clickThrough: element.firstChild(named: "CompanionClickThrough").flatMap {
                                 url($0, at: path + "/CompanionClickThrough", role: .clickThrough)
                             },
                             clickTrackings: urls(element.children(named: "CompanionClickTracking"), at: path + "/CompanionClickTracking",
                                                  role: .tracker),
                             trackingEvents: decodeTrackingEvents(element.firstChild(named: "TrackingEvents"), at: path + "/TrackingEvents"))
    }

    // MARK: - ViewableImpression

    private mutating func decodeViewableImpression(_ element: VASTXMLElement?, at path: String) -> VASTViewableImpression? {
        guard let element else { return nil }
        checkChildren(of: element, at: path)
        return VASTViewableImpression(viewable: urls(element.children(named: "Viewable"), at: path + "/Viewable", role: .tracker),
                                      notViewable: urls(element.children(named: "NotViewable"), at: path + "/NotViewable", role: .tracker),
                                      viewUndetermined: urls(element.children(named: "ViewUndetermined"), at: path + "/ViewUndetermined",
                                                             role: .tracker))
    }

    // MARK: - AdVerifications

    /// VAST 4.x `AdVerifications`, then VAST 3.0-style `Extensions/Extension[@type="AdVerifications"]`.
    private mutating func decodeAllVerifications(of element: VASTXMLElement, at path: String) -> [VASTVerification] {
        var verifications: [VASTVerification] = []
        if let adVerifications = element.firstChild(named: "AdVerifications") {
            verifications += decodeVerifications(adVerifications, at: path + "/AdVerifications", inExtension: false)
        }
        guard let extensions = element.firstChild(named: "Extensions") else { return verifications }
        for (index, extensionElement) in extensions.children(named: "Extension").enumerated()
            where extensionElement.attribute("type")?.trimmingCharacters(in: .whitespaces) == "AdVerifications" {
            let extensionPath = path + "/Extensions/Extension[\(index + 1)]"
            if let nested = extensionElement.firstChild(named: "AdVerifications") {
                verifications += decodeVerifications(nested, at: extensionPath + "/AdVerifications", inExtension: true)
            } else {
                verifications += decodeVerifications(extensionElement, at: extensionPath, inExtension: true)
            }
        }
        return verifications
    }

    private mutating func decodeVerifications(_ element: VASTXMLElement, at path: String, inExtension: Bool) -> [VASTVerification] {
        element.children(named: "Verification").enumerated().map { index, verification in
            decodeVerification(verification, at: path + "/Verification[\(index + 1)]", inExtension: inExtension)
        }
    }

    /// `inExtension`: a VAST 3.0 `Extension[@type="AdVerifications"]`, which carries the VAST 4.1 structure on purpose, so
    /// version checks are skipped.
    private mutating func decodeVerification(_ element: VASTXMLElement, at path: String, inExtension: Bool) -> VASTVerification {
        checkChildren(of: element, at: path)
        if !inExtension { checkIntroducedChildren(of: element, at: path) }
        let vendor = nonEmpty(element.attribute("vendor"))
        if vendor == nil, let version, version >= .v4_1 {
            report(.warning, "vast.verification.vendor.missing", "VAST \(version.rawValue) requires a vendor attribute on <Verification>.",
                   path + "@vendor")
        }

        let scripts = element.children(named: "JavaScriptResource")
        let preferred = scripts.firstIndex { $0.attribute("apiFramework")?.lowercased() == "omid" } ?? scripts.indices.first
        let javaScriptResource = preferred.flatMap { url(scripts[$0], at: path + "/JavaScriptResource[\($0 + 1)]", role: .resource) }
        if scripts.isEmpty {
            if element.firstChild(named: "ExecutableResource") != nil {
                report(.info, "vast.verification.executableResource", "<ExecutableResource> is for non-browser players and is not run.",
                       path + "/ExecutableResource")
            } else {
                report(.warning, "vast.verification.resource.missing", "<Verification> needs a <JavaScriptResource> or <ExecutableResource>.", path)
            }
        }

        return VASTVerification(vendor: vendor, javaScriptResource: javaScriptResource,
                                parameters: nonEmpty(element.firstChild(named: "VerificationParameters")?.trimmedText),
                                trackingEvents: decodeTrackingEvents(element.firstChild(named: "TrackingEvents"), at: path + "/TrackingEvents",
                                                                     verification: true, versionChecks: !inExtension))
    }

    // MARK: - URLs

    private mutating func urls(_ elements: [VASTXMLElement], at path: String, role: VASTURLCheck.Role) -> [String] {
        elements.enumerated().compactMap { index, element in
            url(element, at: path + "[\(index + 1)]", role: role)
        }
    }

    /// The trimmed URL of `element`, checked for `role`; `nil` (and an issue) when empty.
    private mutating func url(_ element: VASTXMLElement, at path: String, role: VASTURLCheck.Role, emptyCode: String = "vast.url.empty",
                              emptySeverity: ValidationIssue.Severity = .warning) -> String? {
        let value = element.trimmedText
        guard !value.isEmpty else {
            report(emptySeverity, emptyCode, "<\(element.name)> has no URL; it is ignored.", path)
            return nil
        }
        checkURL(value, role: role, at: path)
        return value
    }

    private mutating func checkURL(_ url: String, role: VASTURLCheck.Role, at path: String) {
        switch VASTURLCheck.check(url, role: role) {
        case .ok:
            break
        case .insecure:
            if requireSecure {
                report(.warning, "vast.url.insecure", "\(url) is not HTTPS, but the impression requires secure creatives (imp.secure = 1).", path)
            } else {
                report(.info, "vast.url.insecure", "\(url) is not HTTPS; secure inventory (imp.secure = 1) would reject it.", path)
            }
        case let .invalid(reason):
            report(.warning, "vast.url.invalid", "\"\(url)\" is not a usable URL: \(reason).", path)
        }
    }

    // MARK: - Version and structure checks

    /// Reports each child element that the parent's schema does not define.
    private mutating func checkChildren(of element: VASTXMLElement, at path: String) {
        guard let known = VASTSpecRules.knownChildren[element.name] else { return }
        var reported: Set<String> = []
        for child in element.children where !known.contains(child.name) && reported.insert(child.name).inserted {
            let hint = known.first { $0.caseInsensitiveCompare(child.name) == .orderedSame }
                .map { " Element names are case-sensitive: did you mean <\($0)>?" } ?? ""
            report(hint.isEmpty ? .info : .warning, "vast.element.unknown", "<\(child.name)> is not part of <\(element.name)>; it is ignored.\(hint)",
                   path + "/" + child.name)
        }
    }

    /// Reports child elements that are newer than the declared version.
    private mutating func checkIntroducedChildren(of element: VASTXMLElement, at path: String) {
        var reported: Set<String> = []
        for child in element.children where reported.insert(child.name).inserted {
            checkIntroduced(element.name + "/" + child.name, at: path + "/" + child.name)
        }
    }

    private mutating func checkIntroduced(_ feature: String, at path: String) {
        guard let introduced = VASTSpecRules.introducedIn[feature], let version, version < introduced else { return }
        let name = feature.split(separator: "/").last.map(String.init) ?? feature
        report(.info, "vast.element.newerVersion",
               "\(name) was introduced in VAST \(introduced.rawValue), but the document declares \(version.rawValue).", path)
    }

    // MARK: - Values

    private mutating func integerAttribute(_ name: String, of element: VASTXMLElement, at path: String) -> Int? {
        guard let raw = element.attribute(name) else { return nil }
        guard let value = integer(raw) else {
            report(.warning, "vast.attribute.integer.invalid", "\(name)=\"\(raw)\" is not an integer; it is ignored.", path + "@" + name)
            return nil
        }
        return value
    }

    private mutating func booleanAttribute(_ name: String, of element: VASTXMLElement, at path: String) -> Bool? {
        guard let raw = element.attribute(name) else { return nil }
        guard let value = boolean(raw) else {
            report(.warning, "vast.attribute.boolean.invalid", "\(name)=\"\(raw)\" is not a boolean; it is ignored.", path + "@" + name)
            return nil
        }
        return value
    }

    private func integer(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("-") || trimmed.hasPrefix("+") ? trimmed.dropFirst() : Substring(trimmed)
        guard !digits.isEmpty, digits.count <= 12, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(trimmed)
    }

    private func boolean(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1": true
        case "false", "0": false
        default: nil
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private mutating func report(_ severity: ValidationIssue.Severity, _ code: String, _ message: String, _ path: String) {
        issues.append(ValidationIssue(severity, code: code, message: message, path: path))
    }
}
