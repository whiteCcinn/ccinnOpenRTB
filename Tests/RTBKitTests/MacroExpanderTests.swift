import Foundation
import Testing
@testable import RTBKit

@Suite("MacroExpander – OpenRTB ${…}")
struct OpenRTBMacroTests {
    private let context = MacroContext(auctionID: "req-1", bidID: "bid-9", impID: "imp-1", seatID: "seat a", adID: "ad-7", price: 1.23,
                                       currency: "USD", marketBidRatio: 0.5, lossReason: 102, minimumToWin: 2.5)

    @Test func replacesTheAuctionMacros() {
        let result = MacroExpander.expand(
            "https://t.example/w?a=${AUCTION_ID}&b=${AUCTION_BID_ID}&i=${AUCTION_IMP_ID}&s=${AUCTION_SEAT_ID}&ad=${AUCTION_AD_ID}"
                + "&p=${AUCTION_PRICE}&c=${AUCTION_CURRENCY}&m=${AUCTION_MBR}&l=${AUCTION_LOSS}&min=${AUCTION_MIN_TO_WIN}",
            context: context)
        #expect(result.url == "https://t.example/w?a=req-1&b=bid-9&i=imp-1&s=seat%20a&ad=ad-7&p=1.23&c=USD&m=0.5&l=102&min=2.5")
        #expect(result.replaced == ["${AUCTION_ID}", "${AUCTION_BID_ID}", "${AUCTION_IMP_ID}", "${AUCTION_SEAT_ID}", "${AUCTION_AD_ID}",
                                    "${AUCTION_PRICE}", "${AUCTION_CURRENCY}", "${AUCTION_MBR}", "${AUCTION_LOSS}", "${AUCTION_MIN_TO_WIN}"])
        #expect(result.unknown.isEmpty)
    }

    @Test func clearingPriceScenario() {
        // response-input spec: clearing price 1.23 → `1.23` in the tracker URL.
        let result = MacroExpander.expand("https://t.example/win?price=${AUCTION_PRICE}", context: MacroContext(price: 1.23))
        #expect(result.url == "https://t.example/win?price=1.23")
    }

    @Test func wholePricesHaveNoTrailingZero() {
        #expect(MacroExpander.expand("${AUCTION_PRICE}", context: MacroContext(price: 2)).url == "2")
        #expect(MacroExpander.expand("${AUCTION_PRICE}", context: MacroContext(price: 0.1 + 0.2)).url == "0.30000000000000004")
    }

    @Test func encryptedPriceIsSubstitutedVerbatim() {
        let encrypted = "WEp8wQAgH0fN_Tq0vVTVYhSd4pqpKjiRdHB7jw=="
        let result = MacroExpander.expand("https://t.example/win?p=${AUCTION_PRICE}", context: MacroContext(price: 1.23, encryptedPrice: encrypted))
        #expect(result.url == "https://t.example/win?p=" + encrypted)
    }

    @Test func base64VariantIsBase64URLWithoutPadding() {
        // "1.23" → base64 "MS4yMw==" → base64url without padding "MS4yMw".
        // "a?>?" → base64 "YT8+Pw==" → base64url "YT8-Pw" (URL-safe alphabet, no padding).
        let result = MacroExpander.expand("p=${AUCTION_PRICE:B64}&id=${AUCTION_ID:B64}", context: MacroContext(auctionID: "a?>?", price: 1.23))
        #expect(result.url == "p=MS4yMw&id=YT8-Pw")
        #expect(result.replaced == ["${AUCTION_PRICE:B64}", "${AUCTION_ID:B64}"])
    }

    @Test func unknownAlgorithmSuffixIsReportedAndLeftInPlace() {
        let result = MacroExpander.expand("p=${AUCTION_PRICE:A}", context: MacroContext(price: 1))
        #expect(result.url == "p=${AUCTION_PRICE:A}")
        #expect(result.unknown == ["${AUCTION_PRICE:A}"])
    }

    @Test func unknownMacrosAreReportedOnceAndLeftInPlace() {
        let result = MacroExpander.expand("a=${FOO}&b=${FOO}&c=${auction_price}", context: MacroContext(price: 1))
        #expect(result.url == "a=${FOO}&b=${FOO}&c=${auction_price}")
        #expect(result.unknown == ["${FOO}", "${auction_price}"])
        #expect(result.replaced.isEmpty)
    }

    @Test func knownMacroWithoutValueBecomesEmpty() {
        let result = MacroExpander.expand("l=${AUCTION_LOSS}&m=${AUCTION_MIN_TO_WIN}", context: MacroContext())
        #expect(result.url == "l=&m=")
        #expect(result.replaced == ["${AUCTION_LOSS}", "${AUCTION_MIN_TO_WIN}"])
        #expect(result.unknown.isEmpty)
    }

    @Test func nonFinitePricesAreNeverPrinted() {
        #expect(MacroExpander.expand("${AUCTION_PRICE}", context: MacroContext(price: .nan)).url == "")
        #expect(MacroExpander.expand("${AUCTION_PRICE}", context: MacroContext(price: -.infinity)).url == "")
        #expect(MacroExpander.expand("${AUCTION_PRICE}", context: MacroContext(price: 1e300)).url == "1e%2B300") // `+` is encoded like any value byte
    }

    @Test func customMacrosFromOpenRTB3() {
        // OpenRTB 3.0 §4.4: buyer macros are referenced as `${CUSTOM_KEY}` with KEY exactly as in `bid.macro`.
        let context = MacroContext(price: 3, custom: ["CREATIVE_VARIANT": "red car", "AUCTION_PRICE": "999", "cid": "c 1"])
        let result = MacroExpander.expand("https://t.example/c?v=${CUSTOM_CREATIVE_VARIANT}&k=${CUSTOM_cid}&p=${AUCTION_PRICE}", context: context)
        // Standard macros win over a custom key with the same name.
        #expect(result.url == "https://t.example/c?v=red%20car&k=c%201&p=3")
        #expect(result.unknown.isEmpty)
    }

    @Test func userDefinedExchangeMacrosResolveByTheirBareName() {
        let result = MacroExpander.expand("https://t.example/c?u=${CLICK_URL}", context: MacroContext(custom: ["CLICK_URL": "https://x.example/c"]))
        #expect(result.url == "https://t.example/c?u=https%3A%2F%2Fx.example%2Fc")
    }

    @Test func customMacroCaseIsExact() {
        let result = MacroExpander.expand("${CUSTOM_VARIANT}", context: MacroContext(custom: ["variant": "a"]))
        #expect(result.unknown == ["${CUSTOM_VARIANT}"])
    }

    @Test func agreedAlgorithmSuffixTakesTheEncryptedPrice() {
        let context = MacroContext(price: 1.23, encryptedPrice: "ENC=")
        #expect(MacroExpander.expand("${AUCTION_PRICE:A}", context: context).url == "ENC=")
        #expect(MacroExpander.expand("${OPENRTB_PRICE:X1}", context: context).url == "ENC=")
        // `:B64` is base64 of the clear price, not of the encrypted string.
        #expect(MacroExpander.expand("${AUCTION_PRICE:B64}", context: context).url == "MS4yMw")
        // An algorithm on a non-price macro has no stand-in.
        #expect(MacroExpander.expand("${AUCTION_ID:A}", context: MacroContext(auctionID: "a")).unknown == ["${AUCTION_ID:A}"])
    }

    @Test func priceInsideAQueryValueIsNotDoubleEncoded() {
        // The template is kept byte for byte; only the substituted value is encoded, once.
        let template = "https://t.example/w?u=https%3A%2F%2Fd.example%2F%3Fp%3D&p=${AUCTION_PRICE}&id=${AUCTION_ID}"
        let result = MacroExpander.expand(template, context: MacroContext(auctionID: "a%20b", price: 0.5))
        #expect(result.url == "https://t.example/w?u=https%3A%2F%2Fd.example%2F%3Fp%3D&p=0.5&id=a%2520b")
    }

    @Test func discountAndMultiplierMacrosAreKnown() {
        let result = MacroExpander.expand("${AUCTION_DISCOUNT_PCT}|${AUCTION_DISCOUNT_CPM}|${AUCTION_MULTIPLIER}|${OPENRTB_ITEM_QTY}|${OPENRTB_MIN_TO_WIN}",
                                          context: MacroContext(minimumToWin: 0.42, custom: ["AUCTION_MULTIPLIER": "3"]))
        #expect(result.url == "||3||0.42")
        #expect(result.unknown.isEmpty)
    }

    @Test func openRTB3StandardMacros() {
        let result = MacroExpander.expand("${OPENRTB_ID}/${OPENRTB_BID_ID}/${OPENRTB_ITEM_ID}/${OPENRTB_SEAT_ID}/${OPENRTB_PRICE}/${OPENRTB_CURRENCY}/${OPENRTB_LOSS}/${OPENRTB_MEDIA_ID}",
                                          context: context)
        #expect(result.url == "req-1/bid-9/imp-1/seat%20a/1.23/USD/102/ad-7")
        #expect(result.unknown.isEmpty)
    }

    @Test func impressionTimestampIsMillisecondsSinceEpoch() {
        let result = MacroExpander.expand("${AUCTION_IMP_TS}", context: MacroContext(timestamp: Date(timeIntervalSince1970: 1_700_000_000.123)))
        #expect(result.url == "1700000000123")
    }

    @Test func multiplierComesFromCustomValues() {
        #expect(MacroExpander.expand("${AUCTION_MULTIPLIER}", context: MacroContext(custom: ["AUCTION_MULTIPLIER": "2.5"])).url == "2.5")
    }

    @Test func substitutedValuesAreNotRescanned() {
        // A value that itself looks like a macro must never be expanded again (no recursion, no injection).
        let result = MacroExpander.expand("${X}", context: MacroContext(price: 5, custom: ["X": "${AUCTION_PRICE}"]))
        #expect(result.url == "%24%7BAUCTION_PRICE%7D")
    }

    @Test func percentEncodedMacrosAreReportedNotSubstituted() {
        // Spec-compliant exchanges substitute only the literal `${…}`; an encoded one inside a nested redirect stays.
        let template = "https://t.example/r?u=https%3A%2F%2Fd.example%2Fw%3Fp%3D%24%7BAUCTION_PRICE%7D&p=${AUCTION_PRICE}"
        let result = MacroExpander.expand(template, context: MacroContext(price: 1.5))
        #expect(result.url == "https://t.example/r?u=https%3A%2F%2Fd.example%2Fw%3Fp%3D%24%7BAUCTION_PRICE%7D&p=1.5")
        #expect(result.unknown == ["%24%7BAUCTION_PRICE%7D"])
    }

    @Test func malformedTokensAreLeftAlone() {
        let template = "a=${AUCTION_PRICE&b=${}&c=$&d=${A B}&e=[&f=[]&g=[lower]&h=[1X]"
        let result = MacroExpander.expand(template, context: MacroContext(price: 1))
        #expect(result.url == template)
        #expect(result.unknown.isEmpty)
        #expect(result.replaced.isEmpty)
    }

    @Test func valuesArePercentEncodedOnce() {
        let result = MacroExpander.expand("i=${AUCTION_ID}", context: MacroContext(auctionID: "a b&c=d/é%"))
        #expect(result.url == "i=a%20b%26c%3Dd%2F%C3%A9%25")
    }

    @Test func templateIsNeverReencoded() {
        let template = "https://t.example/p?x=%20already%2Fencoded&y=日本"
        #expect(MacroExpander.expand(template, context: MacroContext()).url == template)
    }
}

@Suite("MacroExpander – VAST […]")
struct VASTMacroTests {
    private let utc = TimeZone(identifier: "UTC") ?? .current

    @Test func errorCodeAndCacheBuster() {
        let result = MacroExpander.expand("https://t.example/e?code=[ERRORCODE]&cb=[CACHEBUSTING]",
                                          context: MacroContext(errorCode: 901, cacheBuster: "12345678"))
        #expect(result.url == "https://t.example/e?code=901&cb=12345678")
        #expect(result.replaced == ["[ERRORCODE]", "[CACHEBUSTING]"])
    }

    @Test func randomCacheBusterHasEightDigits() {
        let value = MacroExpander.expand("[CACHEBUSTING]", context: MacroContext()).url
        #expect(value.count == 8)
        #expect(value.allSatisfy { $0.isNumber })
        #expect(value.first != "0")
    }

    @Test func timestampIsISO8601WithMillisecondsAndZoneURLEncoded() {
        let date = Date(timeIntervalSince1970: 1_453_036_507.127) // 2016-01-17T13:15:07.127Z
        let eastern = TimeZone(secondsFromGMT: -5 * 3600) ?? utc
        #expect(MacroExpander.expand("[TIMESTAMP]", context: MacroContext(timestamp: date), timeZone: eastern).url
            == "2016-01-17T08%3A15%3A07.127-05%3A00")
        #expect(MacroExpander.expand("[TIMESTAMP]", context: MacroContext(timestamp: date), timeZone: utc).url
            == "2016-01-17T13%3A15%3A07.127Z")
    }

    @Test func playheadsAreHHMMSSmmm() {
        let context = MacroContext(adPlayhead: 3.5, contentPlayhead: 3_725.0456)
        let result = MacroExpander.expand("a=[ADPLAYHEAD]&c=[CONTENTPLAYHEAD]&m=[MEDIAPLAYHEAD]", context: context)
        #expect(result.url == "a=00%3A00%3A03.500&c=01%3A02%3A05.046&m=01%3A02%3A05.046")
    }

    @Test func unknownValuesAreMinusOne() {
        // VAST 4.1 §6.1: a macro whose value is unknown is replaced with -1.
        let result = MacroExpander.expand("a=[ADPLAYHEAD]&s=[PLAYERSIZE]&u=[ASSETURI]&ua=[DEVICEUA]&e=[ERRORCODE]&ifa=[IFA]",
                                          context: MacroContext())
        #expect(result.url == "a=-1&s=-1&u=-1&ua=-1&e=-1&ifa=-1")
        #expect(result.unknown.isEmpty)
    }

    @Test func playerSizeAssetDeviceAndReason() {
        let device = DeviceProfile(id: "d", name: "D", family: .iPhone, screenWidth: 393, screenHeight: 852, scale: 3, os: "iOS",
                                   osVersion: "18.0", make: "Apple", model: "iPhone15,4", userAgent: "Mozilla/5.0 (iPhone; CPU)",
                                   openRTBDeviceType: 4)
        let context = MacroContext(assetURI: "https://cdn.example/a.mp4?x=1", playerWidth: 640, playerHeight: 360, reason: 2, device: device)
        let result = MacroExpander.expand("s=[PLAYERSIZE]&a=[ASSETURI]&ua=[DEVICEUA]&r=[REASON]", context: context)
        #expect(result.url == "s=640%2C360&a=https%3A%2F%2Fcdn.example%2Fa.mp4%3Fx%3D1&ua=Mozilla%2F5.0%20%28iPhone%3B%20CPU%29&r=2")
    }

    @Test func breakPositionIsDerivedFromTheContentPlayhead() {
        #expect(MacroExpander.expand("[BREAKPOSITION]", context: MacroContext()).url == "4")
        #expect(MacroExpander.expand("[BREAKPOSITION]", context: MacroContext(contentPlayhead: 0)).url == "1")
        #expect(MacroExpander.expand("[BREAKPOSITION]", context: MacroContext(contentPlayhead: 30)).url == "2")
        #expect(MacroExpander.expand("[BREAKPOSITION]", context: MacroContext(custom: ["[BREAKPOSITION]": "3"])).url == "3")
    }

    @Test func requestDerivedValuesUseBracketedCustomKeys() {
        let context = MacroContext(custom: ["[DOMAIN]": "news.example", "[PAGEURL]": "https://news.example/a?b=1", "[APPBUNDLE]": "com.example.app",
                                            "[LIMITADTRACKING]": "0", "[IFA]": "6D92078A-8246-4BA4-AE5B-76104861E7DC", "DOMAIN": "wrong"])
        let result = MacroExpander.expand("d=[DOMAIN]&p=[PAGEURL]&b=[APPBUNDLE]&l=[LIMITADTRACKING]&i=[IFA]", context: context)
        #expect(result.url == "d=news.example&p=https%3A%2F%2Fnews.example%2Fa%3Fb%3D1&b=com.example.app&l=0&i=6D92078A-8246-4BA4-AE5B-76104861E7DC")
    }

    @Test func unknownVASTMacrosAreReported() {
        let result = MacroExpander.expand("https://t.example/i?x=[MY_MACRO]&cb=[CACHEBUSTING]", context: MacroContext(cacheBuster: "11111111"))
        #expect(result.url == "https://t.example/i?x=[MY_MACRO]&cb=11111111")
        #expect(result.unknown == ["[MY_MACRO]"])
    }

    @Test func bothFamiliesInOneURL() {
        let result = MacroExpander.expand("https://t.example/imp?p=${AUCTION_PRICE}&e=[ERRORCODE]", context: MacroContext(price: 0.75, errorCode: 403))
        #expect(result.url == "https://t.example/imp?p=0.75&e=403")
    }

    @Test func supportedVASTVersionsAndServerSide() {
        #expect(MacroExpander.expand("[VASTVERSIONS]", context: MacroContext()).url == "2%2C3%2C5%2C6%2C7%2C8%2C11%2C12%2C13%2C14")
        #expect(MacroExpander.expand("[SERVERSIDE]", context: MacroContext()).url == "0")
    }

    @Test func ipv6HostsAndArrayParametersAreNotMacros() {
        let template = "http://[::1]:8080/p?a[0]=1&b[x]=2"
        let result = MacroExpander.expand(template, context: MacroContext())
        #expect(result.url == template)
        #expect(result.unknown.isEmpty)
    }

    @Test func hugeAndNegativePlayheadsDoNotTrap() {
        #expect(MacroExpander.expand("[ADPLAYHEAD]", context: MacroContext(adPlayhead: -4)).url == "-1")
        #expect(MacroExpander.expand("[ADPLAYHEAD]", context: MacroContext(adPlayhead: .infinity)).url == "-1")
        #expect(MacroExpander.expand("[ADPLAYHEAD]", context: MacroContext(adPlayhead: 1e300)).url == "-1")
    }
}

@Suite("MacroExpander – OpenRTB trackers")
struct OpenRTBTrackerMacroTests {
    @Test func vastMacrosAreNotExpandedInOpenRTBTrackersButReported() {
        // Exchanges substitute only ${…} in nurl/burl/lurl/imptrackers; a [CACHEBUSTING] there reaches the server as is.
        let result = MacroExpander.expandOpenRTB("https://t.example/imp?p=${AUCTION_PRICE}&cb=[CACHEBUSTING]&x=${FOO}",
                                                 context: MacroContext(price: 2, cacheBuster: "12345678"))
        #expect(result.url == "https://t.example/imp?p=2&cb=[CACHEBUSTING]&x=${FOO}")
        #expect(result.replaced == ["${AUCTION_PRICE}"])
        #expect(result.unknown == ["[CACHEBUSTING]", "${FOO}"])
    }
}

@Suite("MacroExpander – markup")
struct MarkupMacroTests {
    @Test func onlyOpenRTBMacrosAreSubstitutedInMarkup() {
        let markup = #"<img src="https://t.example/i?p=${AUCTION_PRICE}&cb=[CACHEBUSTING]"><script>const w = `${width}px`; a[INDEX] = 1;</script>"#
        let result = MacroExpander.expandMarkup(markup, context: MacroContext(price: 1.5))
        #expect(result.url == #"<img src="https://t.example/i?p=1.5&cb=[CACHEBUSTING]"><script>const w = `${width}px`; a[INDEX] = 1;</script>"#)
        #expect(result.replaced == ["${AUCTION_PRICE}"])
        #expect(result.unknown.isEmpty)
    }

    @Test func upperCaseUnknownMarkupMacrosAreReported() {
        let result = MacroExpander.expandMarkup("<a href='https://x.example/?c=${CLICK_URL}'>", context: MacroContext())
        #expect(result.unknown == ["${CLICK_URL}"])
    }
}
