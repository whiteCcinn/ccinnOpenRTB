import RTBKit
import SwiftUI

// What a click-through opened on the device, drawn over the publisher app in its content frame: the third-party app a
// deep link named, the App Store or Google Play page, the in-app browser or a system app — each with the platform's way
// back. Drawn in device points, like the mock apps.

/// The screen a click-through opened.
struct AppJumpView: View {
    let foreground: DeviceForeground
    let layout: ScreenLayout
    /// Where Back returns to.
    let publisherApp: String
    let onBack: () -> Void

    var body: some View {
        let size = layout.contentFrame.size
        screen
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(MockPalette.background)
            .clipped()
            .overlay(alignment: .bottom) { androidBack }
    }

    @ViewBuilder private var screen: some View {
        switch foreground.screen {
        case let .app(app):
            ThirdPartyAppScreen(app: app, usedFallback: foreground.usedFallback, insets: insets)
        case let .store(page):
            StoreScreen(page: page, platform: foreground.platform, usedFallback: foreground.usedFallback, insets: insets, onBack: onBack)
        case let .browser(page):
            InAppBrowserScreen(page: page, platform: foreground.platform, usedFallback: foreground.usedFallback, openedOnMac: foreground.openedOnMac,
                               insets: insets, onBack: onBack)
        case let .system(app, target):
            SystemAppScreen(app: app, target: target, insets: insets, onBack: onBack)
        }
    }

    private var insets: EdgeInsets {
        let area = layout.safeArea
        return EdgeInsets(top: CGFloat(area.top), leading: CGFloat(area.leading), bottom: CGFloat(area.bottom), trailing: CGFloat(area.trailing))
    }

    /// Android's system Back after a jump to another app (iOS has the status bar's "◀ App" instead).
    @ViewBuilder private var androidBack: some View {
        if foreground.platform == .android, foreground.jumpedToAnotherApp {
            Button(action: onBack) {
                Label("Back to \(publisherApp)", systemImage: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, insets.bottom + 12)
            .help("Android's Back: return to the publisher app and the ad")
        }
    }
}

/// iOS's "◀ App" in the status bar after a jump to another app: it returns to the publisher app.
struct BackBreadcrumb: View {
    let publisherApp: String
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 2) {
                Image(systemName: "arrowtriangle.backward.fill").font(.system(size: 7))
                Text(publisherApp).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(MockPalette.background, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("iOS's back link: return to \(publisherApp) and the ad")
    }
}

// MARK: - Shared parts

/// A deterministic app icon: the name's initial on a colour chosen from the name (`inverted`: in that colour on white,
/// for the app's own coloured bar).
private struct AppIconTile: View {
    let name: String
    var size: CGFloat = 56
    var inverted = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(inverted ? AnyShapeStyle(Color.white) : AnyShapeStyle(AppJumpPalette.gradient(for: name)))
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(inverted ? AppJumpPalette.accent(for: name) : .white)
            }
    }
}

enum AppJumpPalette {
    static func accent(for name: String) -> Color {
        let hues: [Double] = [0.02, 0.08, 0.33, 0.55, 0.62, 0.75, 0.85, 0.95]
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: hues[Int(hash % UInt32(hues.count))], saturation: 0.72, brightness: 0.86)
    }

    static func gradient(for name: String) -> LinearGradient {
        let accent = accent(for: name)
        return LinearGradient(colors: [accent, accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Label / value rows: the link and its parameters, selectable.
private struct LinkDetails: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(row.value.isEmpty ? "—" : row.value)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func parameters(_ parameters: [LinkParameter]) -> [(label: String, value: String)] {
        parameters.prefix(30).map { (label: $0.name, value: $0.value) }
    }
}

/// A small "Fallback" note: the link itself could not be opened.
private struct FallbackBadge: View {
    let visible: Bool

    var body: some View {
        if visible {
            Label("The bid's fallback: the link's app is not installed", systemImage: "arrow.uturn.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Third-party app

private struct ThirdPartyAppScreen: View {
    let app: ThirdPartyApp
    let usedFallback: Bool
    let insets: EdgeInsets

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Opened by the ad's deep link").font(.system(size: 15, weight: .semibold))
                    FallbackBadge(visible: usedFallback)
                    LinkDetails(rows: [("Deep link", app.link), ("App", app.identifier), ("Route", app.route)]
                        + LinkDetails.parameters(app.parameters))
                    placeholderContent
                }
                .padding(16)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
            }
        }
        .background(MockPalette.groupedBackground)
    }

    private var header: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: insets.top)
            HStack(spacing: 10) {
                AppIconTile(name: app.name, size: 30, inverted: true)
                Text(app.name).font(.system(size: 18, weight: .bold))
                Spacer()
                Image(systemName: "magnifyingglass").font(.system(size: 17))
            }
            .padding(.horizontal, 16)
            .frame(height: MockMetrics.appBarHeight)
        }
        .foregroundStyle(.white)
        .background(AppJumpPalette.accent(for: app.name))
    }

    /// Where the app's own page would be.
    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(MockPalette.photo(index)).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Color.primary.opacity(0.18)).frame(width: 140, height: 9)
                        Capsule().fill(Color.primary.opacity(0.10)).frame(width: 90, height: 9)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Store

private struct StoreScreen: View {
    let page: StorePage
    let platform: DevicePlatform
    let usedFallback: Bool
    let insets: EdgeInsets
    let onBack: () -> Void

    private var appName: String {
        switch page.store {
        case .googlePlay: page.appID.isEmpty ? "App" : ClickThroughResolver.appName(package: page.appID)
        case .appStore: page.appID.isEmpty ? "App" : "App \(page.appID)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    product
                    FallbackBadge(visible: usedFallback)
                    LinkDetails(rows: [(page.store.rawValue + " link", page.url), ("App", page.appID)] + LinkDetails.parameters(page.parameters))
                }
                .padding(16)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: insets.top)
            HStack {
                Button(action: onBack) {
                    if platform == .apple { Text("Done").font(.system(size: 16, weight: .semibold)) } else { Image(systemName: "arrow.left") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Close the store and return to the ad")
                Spacer()
                Label(page.store.rawValue, systemImage: page.store == .appStore ? "applelogo" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 40, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .background(MockPalette.bar)
        .overlay(alignment: .bottom) { MockPalette.separator.frame(height: 0.5) }
    }

    private var product: some View {
        HStack(spacing: 14) {
            AppIconTile(name: appName, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(appName).font(.system(size: 18, weight: .bold)).lineLimit(2)
                Text("Opened from an ad").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(page.store == .appStore ? "GET" : "Install")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 5)
                    .background(page.store == .appStore ? Color.accentColor : Color.green, in: Capsule())
            }
        }
    }
}

// MARK: - In-app browser

private struct InAppBrowserScreen: View {
    let page: WebPage
    let platform: DevicePlatform
    let usedFallback: Bool
    let openedOnMac: Bool
    let insets: EdgeInsets
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    status
                    FallbackBadge(visible: usedFallback)
                    LinkDetails(rows: [("Landing page", page.url), ("Host", page.host)] + LinkDetails.parameters(page.parameters))
                }
                .padding(16)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
            }
        }
    }

    private var secure: Bool { page.url.lowercased().hasPrefix("https:") }

    /// SFSafariViewController's bar (Done, the host) or a Chrome Custom Tab's (close, the host, menu).
    private var toolbar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: insets.top)
            HStack(spacing: 12) {
                Button(action: onBack) {
                    if platform == .apple { Text("Done").font(.system(size: 16, weight: .semibold)) } else { Image(systemName: "xmark") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Close the browser and return to the ad")
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: secure ? "lock.fill" : "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(page.host.isEmpty ? page.url : page.host).font(.system(size: 14, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(secure ? Color.primary : Color.orange)
                Spacer(minLength: 0)
                Image(systemName: platform == .apple ? "textformat.size" : "ellipsis").font(.system(size: 15)).frame(width: 40)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
        }
        .background(MockPalette.bar)
        .overlay(alignment: .bottom) { MockPalette.separator.frame(height: 0.5) }
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: openedOnMac ? "safari" : "globe").font(.system(size: 22)).foregroundStyle(.secondary)
            Text(openedOnMac ? "Opened in your Mac's default browser too (Real mode)." : "The landing page is not loaded in the simulator.")
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - System app

private struct SystemAppScreen: View {
    let app: SystemApp
    let target: String
    let insets: EdgeInsets
    let onBack: () -> Void

    private var symbol: String {
        switch app {
        case .phone: "phone.fill"
        case .messages: "message.fill"
        case .mail: "envelope.fill"
        }
    }

    private var action: String {
        switch app {
        case .phone: "Call"
        case .messages: "New message to"
        case .mail: "New email to"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.green)
            Text(app.rawValue).font(.system(size: 20, weight: .bold))
            Text("\(action) \(target.isEmpty ? "—" : target)")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Cancel", action: onBack)
                .buttonStyle(.bordered)
                .help("Return to the ad")
            Spacer()
        }
        .padding(.top, insets.top)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Notice

/// A click-through that opened nothing: why, on the device, until dismissed (or a few seconds).
struct ClickThroughNoticeView: View {
    let notice: ClickThroughNotice
    let bottomInset: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "nosign").foregroundStyle(.orange)
            Text(notice.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Dismiss")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, bottomInset + 12)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { onDismiss() }
        }
    }
}
