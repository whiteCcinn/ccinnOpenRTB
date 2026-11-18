import CcinnOpenRTBKit
import Foundation
import RTBKit

/// Launch arguments for automated checks (app-shell's set; kit-network owns `--demo-network` / `--snapshot-network`):
///
///     --sample <id>  --device <id>  --placement <name>  --mode simulated|real
///     --landscape  --folded  --spanned  --visibility <0…1>  --zoom fit|<scale>  --no-render
///     --snapshot <file.png> [--snapshot-delay <s>] [--quit-after-snapshot]  --open-network
///
/// `--mode real` only shows the confirmation: the command line can never switch Real mode on by itself.
struct LaunchOptions: Equatable {
    static let defaultSnapshotDelay = 4.0

    var sampleID: String?
    var deviceID: String?
    var placement: Placement?
    var mode: TrackingMode?
    var landscape = false
    var folded = false
    var spanned = false
    var visibility: Double?
    var zoom: ZoomSetting?
    /// Render after loading the sample (`--no-render` turns it off).
    var renders = true
    var snapshotPath: String?
    var snapshotDelay = LaunchOptions.defaultSnapshotDelay
    var quitAfterSnapshot = false
    var opensNetworkWindow = false
    var isEmpty = true

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let value = arguments[index + 1]
            return value.hasPrefix("--") ? nil : value
        }
        func flag(_ name: String) -> Bool { arguments.contains(name) }

        sampleID = value("--sample")
        deviceID = value("--device")
        placement = value("--placement").flatMap(Self.placement(named:))
        mode = value("--mode").flatMap { TrackingMode(rawValue: $0.lowercased()) }
        landscape = flag("--landscape")
        folded = flag("--folded")
        spanned = flag("--spanned")
        visibility = value("--visibility").flatMap(Double.init).flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        zoom = value("--zoom").flatMap(Self.zoom(_:))
        renders = !flag("--no-render")
        snapshotPath = value("--snapshot")
        if let delay = value("--snapshot-delay").flatMap(Double.init), delay.isFinite, delay >= 0 { snapshotDelay = delay }
        quitAfterSnapshot = flag("--quit-after-snapshot")
        opensNetworkWindow = flag("--open-network")
        let known = ["--sample", "--device", "--placement", "--mode", "--landscape", "--folded", "--spanned", "--visibility", "--zoom",
                     "--no-render", "--snapshot", "--open-network"]
        isEmpty = !known.contains(where: arguments.contains)
    }

    /// `in-feed`, `In-feed`, `inFeed`, `CTV instream` … (letters and digits compared case-insensitively).
    static func placement(named name: String) -> Placement? {
        let wanted = normalised(name)
        return Placement.allCases.first { normalised($0.rawValue) == wanted || normalised(String(describing: $0)) == wanted }
    }

    private static func normalised(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func zoom(_ text: String) -> ZoomSetting? {
        if text.lowercased() == "fit" { return .fit }
        guard let scale = Double(text), scale.isFinite, scale > 0 else { return nil }
        return .scale(ZoomSetting.clamped(scale))
    }

    /// Sets the session up: device and posture, the sample, placement, visibility and zoom, then renders. `--mode real`
    /// asks for confirmation like the toolbar switch does.
    @MainActor
    func apply(to session: AdSession, samples: [Sample]) async {
        if let device = deviceID.flatMap(DeviceCatalog.device(id:)) { session.device = device }
        session.landscape = landscape
        session.folded = folded
        session.spanned = spanned
        var loaded = false
        if let sample = samples.first(where: { $0.id == sampleID }) {
            await session.load(sample, render: false)
            loaded = true
        }
        if let placement { session.placement = placement }
        if let visibility { session.setVisibleFraction(visibility) }
        if let zoom { session.zoom = zoom }
        switch mode {
        case .real?: session.requestRealMode()
        case .simulated?: session.useSimulatedMode()
        case nil: break
        }
        if renders, loaded { session.render() }
    }
}
