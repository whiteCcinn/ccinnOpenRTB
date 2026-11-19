import AppKit
import CcinnOpenRTBKit
import SwiftUI

/// The Settings window: General (appearance, updates, about) and Network.
struct SettingsScene: Scene {
    var body: some Scene {
        Settings {
            SettingsTabs()
                .frame(width: 560)
                .appAppearance()
        }
    }
}

private struct SettingsTabs: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            NetworkSettingsView()
                .tabItem { Label("Network", systemImage: "antenna.radiowaves.left.and.right") }
                .tag("network")
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            UpdateSettingsSections()
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

struct NetworkSettingsView: View {
    @AppStorage(NetworkPreferences.requestTimeoutKey) private var timeout = NetworkPreferences.defaultRequestTimeout
    @AppStorage(NetworkPreferences.openClickThroughsKey) private var openClickThroughs = false
    @AppStorage(NetworkPreferences.clientRedirectsKey) private var clientRedirects = NetworkPreferences.defaultClientRedirects.rawValue

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Every session starts in **Simulated** mode: trackers are recorded and never sent. **Real** mode sends them with the device’s User-Agent after you confirm the tracker hosts, and lasts until you quit or switch back.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(Theme.accent)
                }
                .font(.callout)
            } header: {
                Text("Tracking mode")
            }
            Section("Requests") {
                Picker("Request timeout", selection: $timeout) {
                    ForEach(NetworkPreferences.requestTimeoutChoices, id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                Toggle(isOn: $openClickThroughs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open click-throughs in browser in Real mode")
                        Text("Click-throughs are always recorded. With this on, Real mode also opens them in your default browser. CTV devices never navigate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Client") {
                Picker("Redirects of new requests", selection: $clientRedirects) {
                    ForEach(RedirectPolicy.allCases) { Text(ClientPresentation.title(for: $0)).tag($0.rawValue) }
                }
                Text("Each request keeps its own setting (Redirects, next to Body and Headers). Following redirects to other origins sends your other headers and, on 307/308, the body there too; Authorization, Proxy-Authorization and Cookie stay behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Content") {
                Text("VAST wrappers, media, images and win-notice markup are fetched in both modes because they are needed to render the ad. `data:` URLs and built-in sample media never leave the Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Sample media cache") {
                    Button("Show in Finder") {
                        let directory = SampleMedia.defaultDirectory
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
