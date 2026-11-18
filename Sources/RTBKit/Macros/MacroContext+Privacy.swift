import Foundation

public extension MacroContext {
    /// The pasted request's values that identify or locate a real end user: device identifiers, address, location and
    /// consent strings.
    static let requestIdentifierMacros: Set<String> = ["[IFA]", "[IFATYPE]", "[DEVICEIP]", "[LATLONG]", "[GDPRCONSENT]", "[GPPSTRING]",
                                                       "[GPPSECTIONID]", "[DEVICEUA]"]

    /// This context without the request's personal values, for what the simulator fetches before Real mode is confirmed
    /// (a VAST tag or wrapper URI in Simulated mode): IFA, IFA type, device IP, lat/long, GDPR consent and the GPP string
    /// and section ids are unknown (-1, like any known macro without a value), and `[DEVICEUA]` falls back to the simulated
    /// device's User-Agent — the one the app sends. Every other value is kept. (OpenRTB `us_privacy` and user ids have no
    /// VAST macro.)
    func withoutRequestIdentifiers() -> MacroContext {
        var context = self
        for key in Self.requestIdentifierMacros {
            context.custom[key] = nil
            context.customLists[key] = nil
        }
        return context
    }
}
