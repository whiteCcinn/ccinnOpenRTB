import Foundation
import Network
import os

/// A minimal HTTP/1.1 server on 127.0.0.1 (a random port) that serves the URIs of rewritten HLS playlists to AVFoundation,
/// which will not take HLS segments from a resource loader. It forwards nothing but the route and a single byte range;
/// the handler (the `MediaRouter`) fetches through the monitor. Only routes with the router's current random token
/// exist, so it is no open proxy, and nothing it answers sets a cookie or allows caching.
///
/// One request per connection (`Connection: close`). Requests are read up to `maxHeaderBytes`; anything else is 400.
final class MediaLoopbackProxy: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var range: ByteRange?
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        static func status(_ status: Int) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(HTTPHeaders.reasonPhrase(status).utf8))
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    static let maxHeaderBytes = 16 * 1024

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "io.github.whiteccinn.ccinnopenrtb.media-proxy")
    /// The requests being answered, cancelled by `cancelAll()` and `stop()`.
    private let inFlight = OSAllocatedUnfairLock(initialState: [UUID: Task<Void, Never>]())

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }

    deinit {
        stop()
    }

    /// Starts listening; returns the port.
    func start() async throws -> UInt16 {
        let queue = queue
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            self.receive(connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<UInt16, any Error>? = switch state {
                case .ready: .success(listener.port?.rawValue ?? 0)
                case let .failed(error): .failure(error)
                case .cancelled: .failure(CancellationError())
                default: nil
                }
                guard let result, !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        cancelAll()
    }

    /// Cancels every request being answered (their connections close).
    func cancelAll() {
        let tasks = inFlight.withLock { tasks -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in tasks { task.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil {
                    connection.cancel()
                } else if buffer.count > Self.maxHeaderBytes {
                    Self.send(.status(431), method: "GET", on: connection)
                } else {
                    self.receive(connection, buffer: buffer)
                }
                return
            }
            guard let request = Self.parse(buffer[..<headerEnd.lowerBound]) else {
                Self.send(.status(400), method: "GET", on: connection)
                return
            }
            self.answer(request, on: connection)
        }
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        let id = UUID()
        let handler = handler
        let inFlight = inFlight
        let task = Task {
            let response = await handler(request)
            inFlight.withLock { _ = $0.removeValue(forKey: id) }
            if Task.isCancelled {
                connection.cancel()
            } else {
                Self.send(response, method: request.method, on: connection)
            }
        }
        inFlight.withLock { $0[id] = task }
        // The player hung up: stop fetching for it.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: task.cancel()
            default: break
            }
        }
    }

    private static func send(_ response: Response, method: String, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(HTTPHeaders.reasonPhrase(response.status))\r\n"
        for (name, value) in response.headers where !value.contains(where: { $0 == "\r" || $0 == "\n" }) { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        let payload = method == "HEAD" ? Data(head.utf8) : Data(head.utf8) + response.body
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The request line and the `Range` header; `nil` when it is not HTTP/1.x.
    static func parse(_ head: Data) -> Request? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        var range: ByteRange?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                range = ByteRange(header: String(line[line.index(after: colon)...]))
            }
        }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), range: range)
    }
}
