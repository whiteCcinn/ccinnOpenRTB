import Foundation

/// The VAST versions the simulator knows, ordered by release.
public enum VASTSpecVersion: String, Sendable, Hashable, Comparable, CaseIterable {
    case v2_0 = "2.0"
    case v3_0 = "3.0"
    case v4_0 = "4.0"
    case v4_1 = "4.1"
    case v4_2 = "4.2"

    /// How a declared `version` attribute maps to a known version.
    public enum Interpretation: Sendable, Hashable {
        /// A version this simulator implements (`"4.1"`, and lenient spellings such as `"4.1.0"` or `"3"`).
        case supported(VASTSpecVersion)
        /// A version outside 2.0–4.2. It is parsed as `closest`, best effort (VAST error 102 applies).
        case unsupported(closest: VASTSpecVersion)
        /// Not a version number at all.
        case invalid
    }

    public static func interpret(_ declared: String) -> Interpretation {
        let parts = declared.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard let majorText = parts.first, (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(majorText)
        else { return .invalid }
        // A patch component ("4.1.0") does not change the schema.
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        if let exact = exact(major: major, minor: minor) { return .supported(exact) }
        return .unsupported(closest: closest(major: major, minor: minor))
    }

    public static func < (lhs: VASTSpecVersion, rhs: VASTSpecVersion) -> Bool {
        let order = allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }

    private static func exact(major: Int, minor: Int) -> VASTSpecVersion? {
        switch (major, minor) {
        case (2, 0): .v2_0
        case (3, 0): .v3_0
        case (4, 0): .v4_0
        case (4, 1): .v4_1
        case (4, 2): .v4_2
        default: nil
        }
    }

    private static func closest(major: Int, minor: Int) -> VASTSpecVersion {
        switch major {
        case ..<3: .v2_0
        case 3: .v3_0
        case 4: minor <= 0 ? .v4_0 : minor == 1 ? .v4_1 : .v4_2
        default: .v4_2
        }
    }
}
