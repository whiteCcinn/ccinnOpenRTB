import Foundation

/// One bidder code a Prebid.js version offers: its own adapter, or an alias of another.
public struct PrebidBidder: Sendable, Hashable, Identifiable {
    /// What `adUnits[].bids[].bidder` names.
    public var code: String
    /// The bidder this code is an alias of.
    public var aliasOf: String?
    /// IAB TCF Global Vendor List id.
    public var gvlid: Int?
    /// The module that registers it (`appnexusBidAdapter`): what the loader loads.
    public var module: String

    public var id: String { code }

    public init(code: String, aliasOf: String?, gvlid: Int?, module: String) {
        self.code = code
        self.aliasOf = aliasOf
        self.gvlid = gvlid
        self.module = module
    }
}

/// The official bid adapters of a Prebid.js version, from the files the version publishes. Pure.
public enum PrebidCatalog {
    /// Bidders in a version's metadata: `metadata/modules/<x>BidAdapter.json` (one module: `module` names it) or the
    /// aggregate `metadata/modules.json` (module per key). Components that are not bidders are left out.
    public static func bidders(fromMetadata data: Data, module: String? = nil) -> [PrebidBidder] {
        guard let root = try? JSONValue.parse(data) else { return [] }
        var bidders: [PrebidBidder] = []
        collect(root, module: module, into: &bidders)
        var seen: Set<String> = []
        return bidders.filter { seen.insert($0.code).inserted }
    }

    private static func collect(_ value: JSONValue, module: String?, into bidders: inout [PrebidBidder]) {
        guard case let .object(members) = value else { return }
        if case let .array(components)? = members["components"] {
            for case let .object(component) in components {
                guard case .string("bidder")? = component["componentType"], case let .string(code)? = component["componentName"], !code.isEmpty else {
                    continue
                }
                let alias: String? = if case let .string(name)? = component["aliasOf"], !name.isEmpty, name != code { name } else { nil }
                let gvlid: Int? = switch component["gvlid"] {
                case let .int(number)?: Int(exactly: number)
                case let .double(number)?: number.isFinite && number == number.rounded() ? Int(number) : nil
                default: nil
                }
                bidders.append(PrebidBidder(code: code, aliasOf: alias, gvlid: gvlid, module: module ?? code + "BidAdapter"))
            }
            return
        }
        for (key, nested) in members.sorted(by: { $0.key < $1.key }) {
            collect(nested, module: key.hasSuffix("BidAdapter") ? key : module, into: &bidders)
        }
    }

    /// Bid adapter modules in jsDelivr's flat listing of a version: `dist/chunks/<x>BidAdapter.js`, sorted.
    public static func bidAdapterModules(fromListing data: Data) -> [String] {
        guard case let .object(root)? = try? JSONValue.parse(data), case let .array(files)? = root["files"] else { return [] }
        let prefix = "/dist/chunks/"
        let names = files.compactMap { file -> String? in
            guard case let .object(entry) = file, case let .string(name)? = entry["name"], name.hasPrefix(prefix), name.hasSuffix("BidAdapter.js") else {
                return nil
            }
            return String(name.dropFirst(prefix.count).dropLast(".js".count))
        }
        return Array(Set(names)).sorted()
    }
}
