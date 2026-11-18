import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// The main window's toolbar: device and placement, the tracking mode, Render and the Network window.
struct MainToolbar: ToolbarContent {
    @Bindable var session: AdSession

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DevicePicker(session: session)
        }
        ToolbarItem(placement: .navigation) {
            PlacementPicker(session: session)
        }
        ToolbarItem(placement: .principal) {
            TrackingModeSwitch(session: session)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.render()
            } label: {
                Label("Render", systemImage: "play.fill")
            }
            .help("Render the selected bid (⌘R)")
            NetworkWindowButton()
        }
    }
}

/// Devices grouped by family.
struct DevicePicker: View {
    let session: AdSession

    var body: some View {
        Menu {
            Picker("Device", selection: Binding(get: { session.device.id }, set: { id in
                if let device = DeviceCatalog.device(id: id) { session.device = device }
            })) {
                ForEach(DeviceCatalog.groups) { group in
                    Section(DeviceSymbols.title(for: group.family)) {
                        ForEach(group.devices) { device in
                            Label(device.name, systemImage: DeviceSymbols.symbol(for: device)).tag(device.id)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(session.device.name, systemImage: DeviceSymbols.symbol(for: session.device))
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Simulated device: \(session.device.userAgent)")
        .accessibilityLabel("Device, \(session.device.name)")
    }
}

/// Placements the device offers (CTV: instream only).
struct PlacementPicker: View {
    @Bindable var session: AdSession

    var body: some View {
        Menu {
            Picker("Placement", selection: $session.placement) {
                ForEach(Placement.available(on: session.device)) { placement in
                    Label(placement.rawValue, systemImage: placement.systemImage).tag(placement)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(session.placement.rawValue, systemImage: session.placement.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Where the ad appears in the simulated app")
        .accessibilityLabel("Placement, \(session.placement.rawValue)")
    }
}

/// Offline · Simulated · Real. Real asks first (`requestRealMode`), and is unmistakably red while on; each mode's tooltip
/// says what it loads and sends.
struct TrackingModeSwitch: View {
    let session: AdSession

    var body: some View {
        HStack(spacing: 8) {
            Picker("Network", selection: Binding(get: { session.sessionMode }, set: { session.choose($0) })) {
                ForEach(SessionMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode).help(mode.help)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .help(SessionMode.allCases.map(\.help).joined(separator: "\n"))
            .accessibilityValue(session.sessionMode.help)
            if session.sessionMode == .offline {
                Text("OFFLINE")
                    .font(.caption.weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.gray, in: Capsule())
                    .accessibilityLabel("Offline: nothing is loaded or sent")
            }
            if session.mode == .real {
                Text("REAL")
                    .font(.caption.weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red, in: Capsule())
                    .accessibilityLabel("Real mode is on")
            }
        }
    }
}

/// Shows the session's current confirmation, updating in place while it is presented.
struct RealModeSheetHost: View {
    let session: AdSession

    var body: some View {
        if let confirmation = session.realModeConfirmation {
            RealModeSheet(confirmation: confirmation, contentHosts: session.contactedContentHosts, onConfirm: { session.confirmRealMode(confirmation) },
                          onCancel: { session.cancelRealMode() })
        }
    }
}

/// The confirmation before Real mode: the tracker hosts of the selected bid. Return does not confirm.
struct RealModeSheet: View {
    let confirmation: RealModeConfirmation
    /// The content hosts the current render already contacted (they see the device's requests in Simulated mode too).
    var contentHosts: [TrackerHosts.Host] = []
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// The warning when this auction's notices already went out this session.
    nonisolated static func sentNoticesWarning(_ sent: AuctionReplays.SentNotices) -> String {
        "Win, billing or loss notices for auction \(sent.auctionID) were already sent this session (\(sent.count)). "
            + "Sending again may double-count at the DSP."
    }

    var body: some View {
        let summary = confirmation.summary
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Send real trackers?").font(.title2.weight(.semibold))
                    Text("""
                    Real mode sends the win, billing, impression, viewability, click and loss trackers to their servers with the \
                    device's User-Agent, for this window until you switch back or quit. Live campaigns will count them.
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let bid = confirmation.bidLabel {
                Label(bid, systemImage: "dollarsign.circle").font(.callout)
            }
            if let sent = confirmation.target.sentNotices {
                Label(Self.sentNoticesWarning(sent), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.hosts.isEmpty ? "No tracker hosts found" :
                    "\(summary.hosts.count) host\(summary.hosts.count == 1 ? "" : "s") · \(summary.trackerCount) tracker URL\(summary.trackerCount == 1 ? "" : "s")")
                    .font(.headline)
                if !summary.hosts.isEmpty {
                    List(summary.hosts) { host in
                        HStack {
                            Text(host.name).font(Theme.monospaced)
                            Spacer()
                            Text(host.kinds.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            Text("\(host.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(height: min(220, CGFloat(summary.hosts.count) * 26 + 10))
                }
                ForEach(summary.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !contentHosts.isEmpty {
                ContentHostsSection(hosts: contentHosts)
            }
            HStack {
                Spacer()
                Button("Stay Simulated", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onConfirm) {
                    Text("Send Real Trackers")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

/// The content hosts the render contacted: the ad's VAST, images and media load from them in Simulated mode too (the ad
/// server sees those requests); only Offline loads nothing.
struct ContentHostsSection: View {
    let hosts: [TrackerHosts.Host]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Content hosts this render contacted").font(.subheadline.weight(.semibold))
            Text("The ad's content loads from these in Simulated mode too; choose Offline to load nothing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(hosts) { host in
                HStack {
                    Text(host.name).font(Theme.monospaced)
                    Spacer()
                    Text(host.kinds.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(host.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                }
            }
        }
    }
}
