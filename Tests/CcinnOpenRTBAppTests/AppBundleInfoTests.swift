import Foundation
import Testing

/// `Resources/Info.plist`, which `scripts/build-app.sh` copies into `CcinnOpenRTB.app`.
///
/// Only a bundled app is held to App Transport Security: `swift run` and these tests are not, so nothing but this suite
/// notices a bundle that refuses `http://` — bidder endpoints, trackers, sync partners and media on plain http.
@Suite("App bundle Info.plist")
struct AppBundleInfoTests {
    private static let plistURL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Resources/Info.plist")

    private func info() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.plistURL)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func transportSecurity() throws -> [String: Any] {
        try #require(try info()["NSAppTransportSecurity"] as? [String: Any])
    }

    /// The simulator's own dispatch policy (Offline, Simulated, Real) decides what leaves the Mac, not the host's ATS.
    @Test func allowsCleartextHTTP() throws {
        #expect(try transportSecurity()["NSAllowsArbitraryLoads"] as? Bool == true)
    }

    /// With any of these present, macOS ignores `NSAllowsArbitraryLoads` and refuses http again (-1022), whatever their
    /// value: "allowing" local networking or web content would block every other http load.
    @Test(arguments: ["NSAllowsArbitraryLoadsForMedia", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsLocalNetworking"])
    func nothingRevokesArbitraryLoads(key: String) throws {
        #expect(try transportSecurity()[key] == nil)
    }

    @Test func identifiesTheApp() throws {
        let info = try info()
        #expect(info["CFBundleExecutable"] as? String == "CcinnOpenRTB")
        #expect(info["CFBundleIdentifier"] as? String == "io.github.whiteccinn.ccinnopenrtb")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["LSMinimumSystemVersion"] as? String == "14.0")
    }

    /// The version is stamped by the build script from `CCINNOPENRTB_VERSION`, so the file cannot go stale.
    @Test func carriesNoVersion() throws {
        let info = try info()
        #expect(info["CFBundleShortVersionString"] == nil)
        #expect(info["CFBundleVersion"] == nil)
    }
}
