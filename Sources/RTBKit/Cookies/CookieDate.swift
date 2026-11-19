import Foundation

/// Cookie dates as browsers read them (RFC 6265 §5.1.1): tokens in any order and any of the formats seen in the wild
/// (RFC 1123, RFC 850 with two-digit years, asctime). Pure; `nil` for anything the algorithm rejects.
public enum CookieDate {
    public static func parse(_ text: String) -> Date? {
        var time: (hour: Int, minute: Int, second: Int)?
        var day: Int?
        var month: Int?
        var year: Int?
        for token in tokens(of: text) {
            if time == nil, let parsed = parseTime(token) {
                time = parsed
            } else if day == nil, let value = leadingDigits(token, min: 1, max: 2) {
                day = value
            } else if month == nil, let value = monthIndex(token) {
                month = value
            } else if year == nil, let value = leadingDigits(token, min: 2, max: 4) {
                year = value
            }
        }
        guard let time, let day, let month, var year else { return nil }
        if (70...99).contains(year) { year += 1900 } else if (0...69).contains(year) { year += 2000 }
        guard (1...31).contains(day), year >= 1601, time.hour <= 23, time.minute <= 59, time.second <= 59 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let components = DateComponents(year: year, month: month, day: day, hour: time.hour, minute: time.minute, second: time.second)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return date
    }

    /// RFC 6265 `delimiter`: %x09 / %x20-2F / %x3B-40 / %x5B-60 / %x7B-7E.
    private static func tokens(of text: String) -> [Substring] {
        text.split { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            switch scalar.value {
            case 0x09, 0x20...0x2F, 0x3B...0x40, 0x5B...0x60, 0x7B...0x7E: return true
            default: return false
            }
        }
    }

    /// `1*2DIGIT ":" 1*2DIGIT ":" 1*2DIGIT ( non-digit *OCTET )`.
    private static func parseTime(_ token: Substring) -> (hour: Int, minute: Int, second: Int)? {
        let parts = token.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let hour = digits(parts[0], min: 1, max: 2, wholeToken: true),
              let minute = digits(parts[1], min: 1, max: 2, wholeToken: true), let second = leadingDigits(parts[2], min: 1, max: 2) else { return nil }
        return (hour, minute, second)
    }

    /// `min*maxDIGIT ( non-digit *OCTET )`.
    private static func leadingDigits(_ token: Substring, min: Int, max: Int) -> Int? {
        digits(token, min: min, max: max, wholeToken: false)
    }

    private static func digits(_ token: Substring, min: Int, max: Int, wholeToken: Bool) -> Int? {
        let run = token.prefix { $0.isASCII && $0.isNumber }
        guard run.count >= min, run.count <= max else { return nil }
        if wholeToken, run.count != token.count { return nil }
        return Int(run)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func monthIndex(_ token: Substring) -> Int? {
        guard token.count >= 3 else { return nil }
        return months.firstIndex(of: token.prefix(3).lowercased()).map { $0 + 1 }
    }
}
