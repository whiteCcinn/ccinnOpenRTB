import Foundation

/// How saved requests are written as JSON, on disk and in an export: pretty-printed with sorted keys (a file reads and
/// diffs well) and dates in ISO 8601 with milliseconds (readable, and ordered within a second).
enum SavedRequestCoding {
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Dates are kept to the millisecond: closer than this, two dates are the same date.
    static let datePrecision: TimeInterval = 0.001

    /// `date` is later than `other` by more than the files can tell apart.
    static func isNewer(_ date: Date, than other: Date) -> Bool {
        date.timeIntervalSince(other) > datePrecision
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    /// Reads dates with or without fractional seconds (a hand-edited file).
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = (try? Date(text, strategy: dateStyle)) ?? (try? Date(text, strategy: .iso8601)) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text.prefix(40))")
        }
        return decoder
    }
}

/// The portable file that moves saved requests to another Mac: every request with its last exchange, in one JSON
/// document tagged with `formatIdentifier` and `version`. Pure.
///
/// Reading is defensive (the file comes from elsewhere): it is size-capped, a document of another kind or a newer
/// version is refused with a reason, and a damaged request is skipped and counted without costing the others. A
/// single saved-request file (as found in the Requests folder) is accepted too.
struct SavedRequestArchive: Codable, Sendable {
    static let formatIdentifier = "com.ccinn.openrtb.saved-requests"
    static let currentVersion = 1
    static let defaultMaxBytes = 256 << 20

    var format: String
    var version: Int
    var exportedAt: Date
    var appVersion: String
    var requests: [SavedRequest]

    enum Failure: Error, Equatable, Sendable {
        case tooLarge(limit: Int)
        case notAnArchive
        case newerVersion(Int)
        /// The file could not be read (the reason).
        case unreadableFile(String)

        var message: String {
            switch self {
            case let .tooLarge(limit):
                "The file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)); it was not imported."
            case .notAnArchive:
                "This is not a CcinnOpenRTB saved-requests export (or a saved request)."
            case let .newerVersion(version):
                "The export was made by a newer CcinnOpenRTB (format \(version)); update the app to import it."
            case let .unreadableFile(reason):
                "The file could not be read: \(reason)"
            }
        }
    }

    struct Decoded: Sendable {
        var requests: [SavedRequest]
        /// Entries that could not be read.
        var unreadable: Int
    }

    static func encode(_ requests: [SavedRequest], exportedAt: Date, appVersion: String) throws -> Data {
        try SavedRequestCoding.encoder().encode(SavedRequestArchive(format: formatIdentifier, version: currentVersion, exportedAt: exportedAt,
                                                                    appVersion: appVersion, requests: requests))
    }

    static func decode(_ data: Data, maxBytes: Int = defaultMaxBytes) throws(Failure) -> Decoded {
        guard data.count <= maxBytes else { throw .tooLarge(limit: maxBytes) }
        let decoder = SavedRequestCoding.decoder()
        if let header = try? decoder.decode(Header.self, from: data) {
            guard header.format == formatIdentifier else { throw .notAnArchive }
            guard header.version <= currentVersion else { throw .newerVersion(header.version) }
            guard let body = try? decoder.decode(LenientBody.self, from: data) else { throw .notAnArchive }
            let requests = body.requests.compactMap(\.value)
            return Decoded(requests: requests, unreadable: body.requests.count - requests.count)
        }
        if let single = try? decoder.decode(SavedRequest.self, from: data) { return Decoded(requests: [single], unreadable: 0) }
        throw .notAnArchive
    }

    /// Just enough to tell an export from anything else.
    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    private struct LenientBody: Decodable {
        var requests: [Lenient<SavedRequest>]
    }

    /// An element that decodes to `nil` instead of failing the whole array.
    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: any Decoder) {
            value = try? Value(from: decoder)
        }
    }
}
