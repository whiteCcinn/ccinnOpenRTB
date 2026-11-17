import Foundation

/// VAST time values: `Duration`, `skipoffset` and progress `offset`.
///
/// - A time is `HH:MM:SS` or `HH:MM:SS.mmm`. Minutes and seconds must be below 60, and the fraction may have any
///   number of digits.
/// - An offset is a time, or a percentage of the ad's duration (`n%`, 0–100, decimals allowed).
enum VASTTimeFormat {
    /// `HH:MM:SS(.mmm)` → seconds, or `nil` when the text is not a valid VAST time.
    static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = digits(parts[0], maxLength: 4),
              let minutes = digits(parts[1], maxLength: 2), minutes < 60
        else { return nil }

        let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(secondParts.count),
              let wholeSeconds = digits(secondParts[0], maxLength: 2), wholeSeconds < 60
        else { return nil }

        var fraction = 0.0
        if secondParts.count == 2 {
            let fractionDigits = secondParts[1]
            guard digits(fractionDigits, maxLength: 9) != nil, let value = Double("0." + fractionDigits) else { return nil }
            fraction = value
        }
        return Double(hours * 3600 + minutes * 60 + wholeSeconds) + fraction
    }

    /// A time or a percentage, or `nil` when the text is neither.
    static func offset(from text: String) -> VASTOffset? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("%") else {
            return seconds(from: trimmed).map(VASTOffset.seconds)
        }
        let number = trimmed.dropLast()
        guard !number.isEmpty, number.count <= 12,
              number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              number.first != ".", number.last != ".",
              number.filter({ $0 == "." }).count <= 1,
              let value = Double(number), value.isFinite, (0...100).contains(value)
        else { return nil }
        return .percent(value)
    }

    /// The canonical VAST spelling of an offset (`00:00:10`, `00:00:10.500`, `25%`), used in labels.
    static func format(_ offset: VASTOffset) -> String {
        switch offset {
        case let .percent(value):
            return trimmedNumber(value) + "%"
        case let .seconds(value):
            guard value.isFinite, value >= 0 else { return "00:00:00" }
            // Clamped so that hand-built offsets (`.seconds(1e300)`) cannot overflow `Int`; 10^15 ms is ~277,000 hours.
            let totalMilliseconds = Int(min((value * 1000).rounded(), 1e15))
            let hours = totalMilliseconds / 3_600_000
            let minutes = totalMilliseconds / 60_000 % 60
            let seconds = totalMilliseconds / 1000 % 60
            let milliseconds = totalMilliseconds % 1000
            let base = twoDigits(hours) + ":" + twoDigits(minutes) + ":" + twoDigits(seconds)
            return milliseconds == 0 ? base : base + "." + threeDigits(milliseconds)
        }
    }

    // MARK: - Helpers

    /// Unsigned ASCII digits only (no sign, no spaces), at most `maxLength` of them.
    private static func digits(_ text: Substring, maxLength: Int) -> Int? {
        guard !text.isEmpty, text.count <= maxLength, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    private static func trimmedNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        // `Int(_:)` traps outside its range, so only small whole numbers take that path.
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func threeDigits(_ value: Int) -> String {
        value < 10 ? "00\(value)" : value < 100 ? "0\(value)" : "\(value)"
    }
}
