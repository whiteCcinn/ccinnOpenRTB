import Foundation
import RTBKit

/// HAR 1.2 export (http://www.softwareishard.com/blog/har-12-spec/) with the simulator's own fields under `_ccinn`.
///
/// Every entry is exported, sent or not: a Simulated-mode tracker has status 0, zero timings and
/// `_ccinn.delivery = "simulated"`, so the file shows exactly what would have gone out. `time` always equals the sum of
/// the timings, as the spec requires. Pure and `Sendable`: run it off the main actor for large sessions.
public enum HARExporter {
    /// Bodies longer than this are exported without `content.text`.
    public static let maxBodyTextBytes = 512 * 1024

    /// `bodies` are response bodies, `requestBodies` the bodies of requests that sent one (`postData`), both by entry id.
    public static func data(entries: [NetworkEntry], bodies: [UUID: Data] = [:], requestBodies: [UUID: Data] = [:],
                            creatorVersion: String = AppInfo.version) throws -> Data {
        let document = document(entries: entries, bodies: bodies, requestBodies: requestBodies, creatorVersion: creatorVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func document(entries: [NetworkEntry], bodies: [UUID: Data], requestBodies: [UUID: Data] = [:], creatorVersion: String) -> HARDocument {
        let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let known = Set(entries.map(\.id))
        return HARDocument(log: HARLog(
            version: "1.2",
            creator: HARCreator(name: AppInfo.productName, version: creatorVersion),
            pages: [],
            entries: entries.map { entry($0, body: bodies[$0.id], requestBody: requestBodies[$0.id], known: known, dateStyle: dateStyle) }
        ))
    }

    private static func entry(_ entry: NetworkEntry, body: Data?, requestBody: Data?, known: Set<UUID>,
                              dateStyle: Date.ISO8601FormatStyle) -> HAREntry {
        let timings = harTimings(for: entry)
        let sent = entry.delivery == .network
        let status = entry.status ?? 0
        let error: String? = if case let .failed(message) = entry.state { message } else { nil }
        let mimeType = entry.mimeType ?? HTTPHeaders.mimeType(fromContentType: entry.responseHeader("Content-Type")) ?? ""
        var content = HARContent(size: entry.responseBytes ?? 0, mimeType: mimeType)
        if let body, body.count <= maxBodyTextBytes {
            if TextDecoding.isTextual(mimeType: mimeType) {
                content.text = TextDecoding.string(from: body, charset: HTTPHeaders.charset(fromContentType: entry.responseHeader("Content-Type")))
            } else if !body.isEmpty {
                content.text = body.base64EncodedString()
                content.encoding = "base64"
            }
        }
        return HAREntry(
            startedDateTime: entry.startedAt.formatted(dateStyle),
            time: timings.total,
            request: HARRequest(
                method: entry.method,
                url: entry.url,
                httpVersion: sent ? "HTTP/1.1" : "",
                cookies: [],
                headers: HTTPHeaders.sorted(entry.requestHeaders).map { HARNameValue(name: $0.name, value: $0.value) },
                queryString: URLText.queryItems(entry.url).map { HARNameValue(name: $0.name, value: $0.value) },
                headersSize: -1,
                bodySize: entry.requestBodyBytes ?? (entry.method.uppercased() == "GET" ? 0 : -1),
                postData: postData(entry, body: requestBody)
            ),
            response: HARResponse(
                status: status,
                statusText: HTTPHeaders.reasonPhrase(status),
                httpVersion: status > 0 ? "HTTP/1.1" : "",
                cookies: [],
                headers: HTTPHeaders.sorted(entry.responseHeaders).map { HARNameValue(name: $0.name, value: $0.value) },
                content: content,
                redirectURL: entry.responseHeader("Location") ?? "",
                headersSize: -1,
                bodySize: entry.responseBytes ?? -1
            ),
            cache: HARCache(),
            timings: timings,
            comment: entry.note,
            ccinn: HARCustom(
                id: entry.id.uuidString,
                sequence: entry.sequence,
                category: entry.category.rawValue,
                trigger: entry.trigger,
                source: entry.source,
                mode: entry.sessionMode.rawValue,
                delivery: entry.delivery.rawValue,
                state: stateName(entry.state),
                parent: entry.parentID.flatMap { known.contains($0) ? $0.uuidString : nil },
                template: entry.template,
                macros: HARMacros(replaced: entry.replacedMacros, unknown: entry.unknownMacros),
                isScript: entry.isScript,
                requestHeadersAsSent: entry.requestHeadersAsSent,
                redirectLocation: entry.redirectLocation,
                error: error
            )
        )
    }

    /// HAR `postData` for a request that sent a body: its text (base64 is not part of HAR 1.2 `postData`, so a body that is
    /// not UTF-8 is exported decoded, with replacement characters) and the request's `Content-Type`.
    private static func postData(_ entry: NetworkEntry, body: Data?) -> HARPostData? {
        guard let body, entry.requestBodyBytes != nil else { return nil }
        let mimeType = HTTPHeaders.value("Content-Type", in: entry.requestHeaders) ?? ""
        let text = body.count <= maxBodyTextBytes
            ? TextDecoding.string(from: body, charset: HTTPHeaders.charset(fromContentType: mimeType)) : ""
        return HARPostData(mimeType: mimeType, text: text)
    }

    /// Transport timings when known; otherwise the measured duration as `wait`; zero for entries that never ran.
    static func harTimings(for entry: NetworkEntry) -> HARTimings {
        if let timings = entry.timings {
            return HARTimings(blocked: timings.blocked ?? -1, dns: timings.dns ?? -1, connect: timings.connect ?? -1, send: timings.send,
                              wait: timings.wait, receive: timings.receive, ssl: timings.ssl ?? -1)
        }
        let milliseconds = (entry.duration ?? 0) * 1000
        return HARTimings(blocked: -1, dns: -1, connect: -1, send: 0, wait: milliseconds.isFinite ? max(0, milliseconds) : 0, receive: 0, ssl: -1)
    }

    static func stateName(_ state: NetworkEntryState) -> String {
        switch state {
        case .simulated: "simulated"
        case .blocked: "blocked"
        case .pending: "pending"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

// MARK: - HAR 1.2 document

struct HARDocument: Codable, Sendable {
    var log: HARLog
}

struct HARLog: Codable, Sendable {
    var version: String
    var creator: HARCreator
    var pages: [HARPage]
    var entries: [HAREntry]
}

struct HARCreator: Codable, Sendable {
    var name: String
    var version: String
}

struct HARPage: Codable, Sendable {
    var startedDateTime: String
    var id: String
    var title: String
}

struct HAREntry: Codable, Sendable {
    var startedDateTime: String
    var time: Double
    var request: HARRequest
    var response: HARResponse
    var cache: HARCache
    var timings: HARTimings
    var comment: String?
    var ccinn: HARCustom

    enum CodingKeys: String, CodingKey {
        case startedDateTime, time, request, response, cache, timings, comment
        case ccinn = "_ccinn"
    }
}

struct HARNameValue: Codable, Sendable, Hashable {
    var name: String
    var value: String
}

struct HARRequest: Codable, Sendable {
    var method: String
    var url: String
    var httpVersion: String
    var cookies: [HARNameValue]
    var headers: [HARNameValue]
    var queryString: [HARNameValue]
    var headersSize: Int
    var bodySize: Int
    var postData: HARPostData?
}

struct HARPostData: Codable, Sendable {
    var mimeType: String
    var text: String
}

struct HARResponse: Codable, Sendable {
    var status: Int
    var statusText: String
    var httpVersion: String
    var cookies: [HARNameValue]
    var headers: [HARNameValue]
    var content: HARContent
    var redirectURL: String
    var headersSize: Int
    var bodySize: Int
}

struct HARContent: Codable, Sendable {
    var size: Int
    var mimeType: String
    var text: String?
    var encoding: String?
}

struct HARCache: Codable, Sendable {}

struct HARTimings: Codable, Sendable {
    var blocked: Double
    var dns: Double
    var connect: Double
    var send: Double
    var wait: Double
    var receive: Double
    var ssl: Double

    /// HAR `time`: the sum of the non-negative phases (`ssl` is included in `connect`).
    var total: Double {
        [blocked, dns, connect, send, wait, receive].filter { $0 > 0 }.reduce(0, +)
    }
}

struct HARMacros: Codable, Sendable {
    var replaced: [String]
    var unknown: [String]
}

struct HARCustom: Codable, Sendable {
    var id: String
    var sequence: Int
    var category: String
    var trigger: String
    var source: String
    var mode: String
    var delivery: String
    var state: String
    var parent: String?
    var template: String
    var macros: HARMacros
    var isScript: Bool
    /// `request.headers` are the headers that went over the wire (otherwise: the headers it was, or would be, sent with).
    var requestHeadersAsSent: Bool
    var redirectLocation: String?
    var error: String?
}
