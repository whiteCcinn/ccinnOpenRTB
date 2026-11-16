import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Native content")
struct NativeAdContentTests {
    private let link = AdLink(url: "https://adv.example/title", clickTrackers: ["https://t.example/c"])

    @Test func typedAssetsFillTheirSlots() {
        let ad = NativeAd(assets: [
            NativeAsset(id: 1, content: .title(text: "Great app"), link: link),
            NativeAsset(id: 2, content: .image(url: "https://i/icon.png", width: 80, height: 80, type: .icon)),
            NativeAsset(id: 3, content: .image(url: "https://i/main.png", width: 1200, height: 627, type: .main)),
            NativeAsset(id: 4, content: .data(value: "Acme", label: nil, type: .sponsored)),
            NativeAsset(id: 5, content: .data(value: "4.5", label: nil, type: .rating)),
            NativeAsset(id: 6, content: .data(value: "Install", label: nil, type: .callToAction)),
            NativeAsset(id: 7, content: .video(vastTag: "<VAST version=\"4.0\"/>")),
            NativeAsset(id: 8, content: .data(value: "Second", label: nil, type: .sponsored)),
        ])
        let content = NativeAdContent(ad: ad)
        #expect(content.title == NativeTextItem(assetID: 1, text: "Great app", link: link, inferred: false))
        #expect(content.icon?.assetID == 2)
        #expect(content.mainImage?.assetID == 3)
        #expect(content.sponsored?.text == "Acme", "the first asset of a type wins")
        #expect(content.rating == 4.5)
        #expect(content.callToAction?.text == "Install")
        #expect(content.video?.assetID == 7)
        #expect(content.inferredAssetIDs.isEmpty)
    }

    @Test func untypedAssetsAreInferredAndMarked() {
        let ad = NativeAd(assets: [
            NativeAsset(id: 1, content: .image(url: "https://i/a.png", width: 1200, height: 628, type: nil), typeSource: .unknown),
            NativeAsset(id: 2, content: .image(url: "https://i/b.png", width: 100, height: 100, type: nil), typeSource: .unknown),
            NativeAsset(id: 3, content: .data(value: "Acme Corp", label: nil, type: nil), typeSource: .unknown),
            NativeAsset(id: 4, content: .data(value: "The quickest way to plan your next trip, now with offline maps.", label: nil, type: nil)),
            NativeAsset(id: 5, content: .data(value: "Learn more", label: nil, type: nil)),
            NativeAsset(id: 6, content: .data(value: "$4.99", label: nil, type: nil)),
            NativeAsset(id: 7, content: .data(value: "4.2", label: nil, type: nil)),
            NativeAsset(id: 8, content: .data(value: "acme.example", label: nil, type: nil)),
            NativeAsset(id: 9, content: .data(value: "x", label: "Sponsored by", type: nil)),
        ])
        let content = NativeAdContent(ad: ad)
        #expect(content.mainImage?.assetID == 1)
        #expect(content.icon?.assetID == 2)
        #expect(content.sponsored?.assetID == 3)
        #expect(content.body?.assetID == 4)
        #expect(content.callToAction?.assetID == 5)
        #expect(content.price?.assetID == 6)
        #expect(content.rating == 4.2)
        #expect(content.displayURL?.assetID == 8)
        #expect(content.inferredAssetIDs == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func parserInferredTypesStayMarked() {
        let ad = NativeAd(assets: [NativeAsset(id: 4, content: .data(value: "Acme", label: nil, type: .sponsored), typeSource: .inferred)])
        #expect(NativeAdContent(ad: ad).inferredAssetIDs == [4])
    }

    @Test func classifierUsesLabelsThenValues() {
        #expect(NativeDataClassifier.classify(value: "anything", label: "Rating") == .rating)
        #expect(NativeDataClassifier.classify(value: "anything", label: "Sale price") == .salePrice)
        #expect(NativeDataClassifier.classify(value: "FREE", label: nil) == .price)
        #expect(NativeDataClassifier.classify(value: "12.50 MYR", label: nil) == .price)
        #expect(NativeDataClassifier.classify(value: "Download now", label: nil) == .callToAction)
        #expect(NativeDataClassifier.classify(value: "1M+ downloads", label: nil) == .downloads)
        #expect(NativeDataClassifier.classify(value: "https://www.acme.example/p", label: nil) == .displayURL)
    }

    @Test func stars() {
        #expect(NativeAdContent.stars("4,5 stars") == 4.5)
        #expect(NativeAdContent.stars("9") == 5)
        #expect(NativeAdContent.stars("n/a") == nil)
    }

    @Test func layoutChoice() {
        let icon = NativeAsset(id: 1, content: .image(url: "i", width: 80, height: 80, type: .icon))
        let main = NativeAsset(id: 2, content: .image(url: "m", width: 1200, height: 627, type: .main))
        let title = NativeAsset(id: 3, content: .title(text: "T"))
        let rating = NativeAsset(id: 4, content: .data(value: "4", label: nil, type: .rating))
        let install = NativeAsset(id: 5, content: .data(value: "Install now", label: nil, type: .callToAction))
        let shop = NativeAsset(id: 6, content: .data(value: "Shop now", label: nil, type: .callToAction))

        func layout(_ assets: [NativeAsset], _ placement: Placement = .inFeed) -> NativeLayoutKind {
            NativeLayoutKind.choose(placement: placement, content: NativeAdContent(ad: NativeAd(assets: assets)))
        }
        #expect(layout([icon, title, main, rating]) == .appInstall)
        #expect(layout([icon, title, main, install]) == .appInstall)
        #expect(layout([icon, title, main, shop]) == .inFeedCard)
        #expect(layout([title, main, shop]) == .contentStream)
        #expect(layout([icon, title, main, shop], .interstitial) == .contentStream)
        #expect(layout([title, shop]) == .inFeedCard)
    }
}
