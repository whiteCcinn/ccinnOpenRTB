import RTBKit
import SwiftUI

// The mock publisher apps the ad appears in. They are drawn in device points and follow the Mac's light/dark appearance
// (as an app would follow the phone's).

/// Colours of the mock apps.
enum MockPalette {
    static let newsAccent = Color(red: 0.72, green: 0.11, blue: 0.16)
    static let feedAccent = Color(red: 0.16, green: 0.42, blue: 0.95)
    static let background = Color(nsColor: .textBackgroundColor)
    static let groupedBackground = Color(nsColor: NSColor.adaptive(light: .hex(0xF2F2F7), dark: .hex(0x1C1C1E)))
    static let card = Color(nsColor: NSColor.adaptive(light: .white, dark: .hex(0x2C2C2E)))
    static let bar = Color(nsColor: NSColor.adaptive(light: .hex(0xF9F9F9), dark: .hex(0x161618)))
    static let separator = Color.primary.opacity(0.12)

    /// Deterministic "photo" gradients.
    static func photo(_ index: Int) -> LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 0.98, green: 0.62, blue: 0.29), Color(red: 0.86, green: 0.25, blue: 0.38)],
            [Color(red: 0.25, green: 0.66, blue: 0.86), Color(red: 0.18, green: 0.32, blue: 0.70)],
            [Color(red: 0.42, green: 0.80, blue: 0.55), Color(red: 0.10, green: 0.48, blue: 0.45)],
            [Color(red: 0.70, green: 0.55, blue: 0.95), Color(red: 0.35, green: 0.24, blue: 0.72)],
            [Color(red: 0.96, green: 0.80, blue: 0.36), Color(red: 0.88, green: 0.48, blue: 0.20)],
        ]
        let colors = palettes[((index % palettes.count) + palettes.count) % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let photoSymbols = ["mountain.2.fill", "building.2.fill", "leaf.fill", "airplane", "sun.max.fill", "tram.fill"]
}

/// App bar + tab bar heights shared by the phone apps.
enum MockMetrics {
    static let appBarHeight = FeedGeometry.appBarHeight
    static let tabBarHeight = FeedGeometry.tabBarHeight
}

// MARK: - News article (inline banner)

/// A news article with an anchored banner slot at the top (below the app bar) or the bottom (above the tab bar). The
/// viewability slider slides the banner out of its slot.
struct NewsArticleApp<Banner: View>: View {
    let layout: ScreenLayout
    let size: CGSize
    let banner: BannerPosition?
    let bannerHeight: CGFloat
    let visibleFraction: Double
    @ViewBuilder let bannerContent: () -> Banner

    static var slotPadding: CGFloat { 6 }

    var body: some View {
        let insets = layout.safeArea
        VStack(spacing: 0) {
            MockAppBar(title: "The Daily Brief", accent: MockPalette.newsAccent, symbol: "newspaper.fill", topInset: CGFloat(insets.top))
            if banner == .top { bannerSlot(edge: .top) }
            ArticleBody(width: size.width - CGFloat(insets.leading + insets.trailing))
                .padding(.leading, CGFloat(insets.leading))
                .padding(.trailing, CGFloat(insets.trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            if banner == .bottom { bannerSlot(edge: .bottom) }
            MockTabBar(accent: MockPalette.newsAccent, items: [("house.fill", "Home"), ("magnifyingglass", "Search"),
                                                               ("bookmark", "Saved"), ("person", "Profile")],
                       bottomInset: CGFloat(insets.bottom))
        }
        .frame(width: size.width, height: size.height)
        .background(MockPalette.background)
    }

    private func bannerSlot(edge: VerticalEdge) -> some View {
        let slot = bannerHeight + Self.slotPadding * 2
        let hidden = CGFloat(1 - min(1, max(0, visibleFraction))) * slot
        return ZStack {
            MockPalette.groupedBackground
            bannerContent()
                .offset(y: edge == .top ? -hidden : hidden)
        }
        .frame(height: slot)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: edge == .top ? .bottom : .top) { MockPalette.separator.frame(height: 0.5) }
    }
}

private struct ArticleBody: View {
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORLD · 6 MIN READ")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(MockPalette.newsAccent)
            Text("Northern towns turn long winter nights into a light festival")
                .font(.system(size: width > 600 ? 30 : 22, weight: .bold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Circle().fill(MockPalette.photo(3)).frame(width: 24, height: 24)
                Text("By Lena Varga").font(.system(size: 12, weight: .semibold))
                Text("· 17 Nov").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MockPalette.photo(1))
                .overlay(Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(.white.opacity(0.85)))
                .frame(height: min(260, width * 0.56))
            ForEach(Array(Self.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 15, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    static let paragraphs = [
        "When the sun sets before four in the afternoon, the harbour fills with lanterns. Volunteers spend weeks wiring the old fishing boats, and by December the whole bay glows.",
        "“It started as a way to get people out of their houses,” says the festival’s organiser. “Now visitors fly in from all over the world.”",
        "Local businesses report their busiest season in a decade, and the town council plans to extend the event into January.",
    ]
}

// MARK: - Feed (in-feed)

/// A social feed whose scroll position (`offset`) decides how much of the in-feed ad is in view.
struct FeedApp<Ad: View>: View {
    let layout: ScreenLayout
    let size: CGSize
    let geometry: FeedGeometry
    let offset: CGFloat
    let captioned: Bool
    @ViewBuilder let ad: () -> Ad

    var body: some View {
        let insets = layout.safeArea
        let viewport = geometry.viewport
        VStack(spacing: 0) {
            MockAppBar(title: "Pulse", accent: MockPalette.feedAccent, symbol: "bolt.heart.fill", topInset: CGFloat(insets.top))
            ZStack(alignment: .topLeading) {
                ForEach(Array(geometry.items.enumerated()), id: \.offset) { _, item in
                    // The ad stays mounted while scrolled away (its renderer keeps running); posts are culled.
                    if item.kind == .ad || isVisible(item.frame, viewportHeight: viewport.height) {
                        itemView(item)
                            .frame(width: geometry.columnWidth, height: item.frame.height)
                            .offset(x: (viewport.width - geometry.columnWidth) / 2, y: item.frame.minY - offset)
                    }
                }
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
            .padding(.leading, CGFloat(insets.leading))
            .padding(.trailing, CGFloat(insets.trailing))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MockPalette.groupedBackground)
            MockTabBar(accent: MockPalette.feedAccent, items: [("house.fill", "Feed"), ("safari", "Explore"),
                                                               ("bell", "Activity"), ("person.crop.circle", "Me")],
                       bottomInset: CGFloat(insets.bottom))
        }
        .frame(width: size.width, height: size.height)
        .background(MockPalette.background)
    }

    private func isVisible(_ frame: CGRect, viewportHeight: CGFloat) -> Bool {
        frame.maxY - offset > -40 && frame.minY - offset < viewportHeight + 40
    }

    @ViewBuilder private func itemView(_ item: FeedGeometry.Item) -> some View {
        switch item.kind {
        case let .post(index):
            FeedPost(index: index)
        case .ad:
            VStack(spacing: 0) {
                if captioned {
                    HStack {
                        Text("Advertisement").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(height: FeedGeometry.adCaptionHeight)
                }
                ad()
            }
        }
    }
}

private struct FeedPost: View {
    let index: Int

    private static let authors = ["Maya Chen", "Daniel Okafor", "Sofia Ruiz", "Arjun Mehta", "Hana Sato", "Tom Becker"]
    private static let texts = [
        "Sunrise hike before work. Worth every minute of lost sleep.",
        "Our tiny balcony garden finally produced tomatoes 🍅",
        "Trying the new tram line today — 12 minutes door to door.",
        "Weekend project: restoring a 1970s desk lamp.",
        "Rainy Sunday, good book, better coffee.",
        "Behind the scenes at the city marathon.",
    ]

    var body: some View {
        let height = FeedGeometry.postHeights[index % FeedGeometry.postHeights.count]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(MockPalette.photo(index + 2)).frame(width: 30, height: 30)
                    .overlay(Text(String(Self.authors[index % Self.authors.count].prefix(1))).font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.authors[index % Self.authors.count]).font(.system(size: 13, weight: .semibold))
                    Text("\(index * 7 % 50 + 3) min").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            Text(Self.texts[index % Self.texts.count]).font(.system(size: 14)).lineLimit(2)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MockPalette.photo(index))
                .overlay(Image(systemName: MockPalette.photoSymbols[index % MockPalette.photoSymbols.count])
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.85)))
                .frame(maxHeight: .infinity)
            HStack(spacing: 18) {
                Label("\(index * 13 % 90 + 4)", systemImage: "heart")
                Label("\(index * 5 % 20 + 1)", systemImage: "bubble.right")
                Image(systemName: "paperplane")
                Spacer()
                Image(systemName: "bookmark")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(height: height)
        .background(MockPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Shared bars

struct MockAppBar: View {
    let title: String
    let accent: Color
    let symbol: String
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .medium))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(accent)
                    Text(title).font(.system(size: 18, weight: .heavy, design: .serif))
                }
                Spacer()
                Image(systemName: "person.crop.circle").font(.system(size: 19))
            }
            .padding(.horizontal, 16)
            .frame(height: MockMetrics.appBarHeight)
        }
        .background(MockPalette.bar)
        .overlay(alignment: .bottom) { MockPalette.separator.frame(height: 0.5) }
    }
}

struct MockTabBar: View {
    let accent: Color
    let items: [(symbol: String, title: String)]
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 2) {
                        Image(systemName: item.symbol).font(.system(size: 18))
                        Text(item.title).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(index == 0 ? accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: MockMetrics.tabBarHeight)
            Color.clear.frame(height: bottomInset)
        }
        .background(MockPalette.bar)
        .overlay(alignment: .top) { MockPalette.separator.frame(height: 0.5) }
    }
}

// MARK: - Dual-screen companion pane

/// The second screen of a dual-screen device when the app uses one screen: a story list.
struct StoryListPane: View {
    let layout: ScreenLayout
    let size: CGSize

    var body: some View {
        VStack(spacing: 0) {
            MockAppBar(title: "Top stories", accent: MockPalette.newsAccent, symbol: "list.bullet.rectangle", topInset: CGFloat(layout.safeArea.top))
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { index in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6).fill(MockPalette.photo(index)).frame(width: 64, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.titles[index % Self.titles.count]).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Text("\(index + 2) h ago").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { MockPalette.separator.frame(height: 0.5).padding(.leading, 92) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(width: size.width, height: size.height)
        .background(MockPalette.background)
    }

    private static let titles = [
        "Markets steady ahead of rate decision", "New rail link opens next spring", "The quiet comeback of film cameras",
        "City parks get 2,000 new trees", "Inside the race for cheaper batteries", "Five weekend trips by train",
        "Chess club becomes the town's hottest ticket", "What the warm autumn means for skiing",
    ]
}

// MARK: - Connected TV

/// The TV home screen shown before the instream ad plays.
struct TVHomeApp: View {
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.10), Color(red: 0.10, green: 0.12, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 44) {
                HStack(spacing: 48) {
                    ForEach(["Home", "Movies", "Shows", "Live", "Sports"], id: \.self) { item in
                        Text(item).font(.system(size: 30, weight: item == "Home" ? .bold : .medium))
                            .foregroundStyle(item == "Home" ? .white : .white.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(.white.opacity(0.7))
                }
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(MockPalette.photo(1))
                    VStack(alignment: .leading, spacing: 14) {
                        Text("NEW SEASON").font(.system(size: 22, weight: .heavy)).tracking(2).foregroundStyle(.white.opacity(0.8))
                        Text("Northern Lights").font(.system(size: 72, weight: .bold, design: .serif)).foregroundStyle(.white)
                        HStack(spacing: 16) {
                            Label("Play S2 E3", systemImage: "play.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .padding(.horizontal, 30).padding(.vertical, 14)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                            Text("Episode 3 · The Long Road · 48 min").font(.system(size: 24)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(48)
                }
                .frame(height: 470)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Continue watching").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    HStack(spacing: 28) {
                        ForEach(0..<5, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(MockPalette.photo(index + 2))
                                .overlay(Image(systemName: MockPalette.photoSymbols[index]).font(.system(size: 44)).foregroundStyle(.white.opacity(0.8)))
                                .overlay(alignment: .bottom) {
                                    GeometryReader { proxy in
                                        Capsule().fill(.white.opacity(0.3)).frame(height: 6)
                                            .overlay(alignment: .leading) {
                                                Capsule().fill(.white).frame(width: proxy.size.width * CGFloat(index + 2) / 8, height: 6)
                                            }
                                    }
                                    .frame(height: 6)
                                    .padding(16)
                                }
                                .frame(width: 320, height: 180)
                                .scaleEffect(index == 0 ? 1.06 : 1)
                                .shadow(color: index == 0 ? .black.opacity(0.5) : .clear, radius: 20, y: 10)
                        }
                    }
                }
            }
            .padding(.horizontal, 96)
            .padding(.top, 60)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Occlusion

/// Covers the bottom part of a full-screen ad (a system sheet slid over it) when the viewability slider is below 100%.
struct OcclusionSheet: View {
    let size: CGSize
    let visibleFraction: Double
    let television: Bool

    var body: some View {
        let covered = CGFloat(1 - min(1, max(0, visibleFraction))) * size.height
        if covered > 0.5 {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: television ? 18 : 8) {
                    Capsule().fill(Color.secondary.opacity(0.5)).frame(width: television ? 90 : 36, height: television ? 8 : 5)
                    Label(television ? "Overlay covering the ad" : "System sheet covering the ad", systemImage: "rectangle.bottomhalf.inset.filled")
                        .font(.system(size: television ? 28 : 13, weight: .semibold))
                    Text("\(Int((visibleFraction * 100).rounded()))% of the ad in view")
                        .font(.system(size: television ? 24 : 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, television ? 20 : 8)
                .frame(maxWidth: .infinity)
                .frame(height: covered, alignment: .top)
                .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: television ? 30 : 14, topTrailingRadius: television ? 30 : 14))
                .clipped()
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }
    }
}
