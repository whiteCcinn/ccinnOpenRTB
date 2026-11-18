import CcinnOpenRTBKit
import Foundation

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

    init(status: Int, headers: [String: String], body: String, bodyBytes: Int, durationMilliseconds: Double, receivedAt: Date, url: String) {
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyBytes = bodyBytes
        self.durationMilliseconds = durationMilliseconds
        self.receivedAt = receivedAt
        self.url = url
    }

    init(_ response: ComposedResponse, receivedAt: Date) {
        let contentType = HTTPHeaders.value("Content-Type", in: response.headers)
        self.init(status: response.status, headers: response.headers,
                  body: TextDecoding.string(from: response.body, charset: HTTPHeaders.charset(fromContentType: contentType)),
                  bodyBytes: response.body.count, durationMilliseconds: max(0, response.duration * 1000), receivedAt: receivedAt,
                  url: response.url.absoluteString)
    }

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
