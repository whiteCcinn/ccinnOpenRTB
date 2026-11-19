import CcinnOpenRTBKit
import Foundation

/// One request of a response's redirect chain, as the Client shows and saves it.
struct ClientRedirectHop: Codable, Hashable, Sendable {
    var method: String
    var url: String
    var status: Int?
    var location: String?
    var bodyBytes: Int?
    var durationMilliseconds: Double?
    /// What changed on the way (method, body, headers left behind, a downgrade to http).
    var note: String?
    var wasSent: Bool
    /// Why it failed or was not sent.
    var failure: String?

    init(_ hop: ComposedHop) {
        method = hop.method
        url = hop.url
        status = hop.status
        location = hop.location
        bodyBytes = hop.bodyBytes
        durationMilliseconds = hop.duration.map { max(0, $0 * 1000) }
        note = hop.note
        wasSent = hop.wasSent
        failure = hop.failure
    }
}

/// What an endpoint answered, as the Client shows and saves it.
struct ClientResponse: Codable, Hashable, Sendable {
    var status: Int
    var headers: [String: String]
    /// The body as text (decoded with the response's charset; bid responses are JSON).
    var body: String
    var bodyBytes: Int
    var durationMilliseconds: Double
    var receivedAt: Date
    /// The URL that answered (after redirects).
    var url: String
    /// Every request of the chain: the request, each redirect hop, a hop not sent. Empty for responses saved by 1.1.0.
    var chain: [ClientRedirectHop]
    /// Why the chain ended on a redirect (not followed, a loop, too many hops).
    var redirectStop: String?
    /// Following every redirect would take the chain further (it stopped because of the request's setting, not a dead end).
    var stopCanBeFollowed: Bool

    init(status: Int, headers: [String: String], body: String, bodyBytes: Int, durationMilliseconds: Double, receivedAt: Date, url: String,
         chain: [ClientRedirectHop] = [], redirectStop: String? = nil, stopCanBeFollowed: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyBytes = bodyBytes
        self.durationMilliseconds = durationMilliseconds
        self.receivedAt = receivedAt
        self.url = url
        self.chain = chain
        self.redirectStop = redirectStop
        self.stopCanBeFollowed = stopCanBeFollowed
    }

    init(_ response: ComposedResponse, receivedAt: Date) {
        let contentType = HTTPHeaders.value("Content-Type", in: response.headers)
        self.init(status: response.status, headers: response.headers,
                  body: TextDecoding.string(from: response.body, charset: HTTPHeaders.charset(fromContentType: contentType)),
                  bodyBytes: response.body.count, durationMilliseconds: max(0, response.duration * 1000), receivedAt: receivedAt,
                  url: response.url.absoluteString, chain: response.chain.map(ClientRedirectHop.init), redirectStop: response.redirectStop?.description,
                  stopCanBeFollowed: response.redirectStop?.canBeFollowed ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case status, headers, body, bodyBytes, durationMilliseconds, receivedAt, url, chain, redirectStop, stopCanBeFollowed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Int.self, forKey: .status)
        headers = try container.decode([String: String].self, forKey: .headers)
        body = try container.decode(String.self, forKey: .body)
        bodyBytes = try container.decode(Int.self, forKey: .bodyBytes)
        durationMilliseconds = try container.decode(Double.self, forKey: .durationMilliseconds)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        url = try container.decode(String.self, forKey: .url)
        // Lenient: a damaged chain costs the chain, not the saved request and its response.
        chain = (try? container.decodeIfPresent([ClientRedirectHop].self, forKey: .chain)) ?? []
        redirectStop = try? container.decodeIfPresent(String.self, forKey: .redirectStop)
        stopCanBeFollowed = (try? container.decodeIfPresent(Bool.self, forKey: .stopCanBeFollowed)) ?? false
    }

    /// Redirects that were followed (the hops sent after the request itself).
    var redirectCount: Int { max(0, chain.filter(\.wasSent).count - 1) }

    /// The answer is a redirect left unfollowed by the request's setting: following every redirect would go further.
    var canFollowFurther: Bool { (300..<400).contains(status) && redirectStop != nil && stopCanBeFollowed }

    var mimeType: String? { HTTPHeaders.mimeType(fromContentType: HTTPHeaders.value("Content-Type", in: headers)) }

    var isSuccess: Bool { (200..<300).contains(status) }

    /// A 2xx with a body: something for the simulator (a bid, or a no-bid response with its `nbr`). A 204 or an empty
    /// body is no bid; any other status is an error the simulator has nothing to show for.
    var carriesAResponseToRender: Bool {
        isSuccess && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A response and what produced it: the body that was sent and the device it was sent as. Rendering a saved response
/// pairs it with exactly this request, whatever the draft says now.
struct ClientExchange: Codable, Hashable, Sendable {
    var requestBody: String
    var response: ClientResponse
    /// `DeviceProfile.id` of the simulated device (its User-Agent went with the request; the response renders on it).
    var deviceID: String?
}

/// A request kept in the library, with its last exchange. One JSON file each (`SavedRequestStore`).
struct SavedRequest: Codable, Hashable, Identifiable, Sendable {
    /// The file format; a later format can read this one.
    static let currentFormat = 1

    var format: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var request: ClientRequest
    var exchange: ClientExchange?

    init(id: UUID, name: String, createdAt: Date, updatedAt: Date, request: ClientRequest, exchange: ClientExchange?) {
        format = Self.currentFormat
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.request = request
        self.exchange = exchange
    }

    /// "ssp.example/openrtb2/auction" for an unnamed request; "Untitled request" without a URL.
    static func defaultName(for request: ClientRequest) -> String {
        let place = URLText.hostAndPath(request.trimmedURL)
        return place.isEmpty ? "Untitled request" : place
    }
}
