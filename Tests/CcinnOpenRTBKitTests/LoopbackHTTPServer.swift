import Foundation
import Network
import os
@testable import CcinnOpenRTBKit

/// A loopback HTTP/1.1 server for wire-level tests: it captures every request exactly as it arrived (method, path and
/// headers) and answers through a handler. One request per connection (`Connection: close`), so `connectionCount` is
/// also the number of requests that reached the socket.
final class LoopbackHTTPServer: Sendable {
    struct Request: Sendable, Hashable {
        var method: String
        var path: String
        /// Header names lowercased.
        var headers: [String: String]

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
        /// Answer only after this long (the connection stays open meanwhile).
        var delay: Duration?

        init(status: Int, headers: [String: String] = [:], body: Data = Data(), delay: Duration? = nil) {
            self.status = status
            self.headers = headers
            self.body = body
            self.delay = delay
        }

        static func text(_ text: String, status: Int = 200, type: String = "text/plain", headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers.merging(["Content-Type": type]) { current, _ in current }, body: Data(text.utf8))
        }

        static func redirect(to location: String, status: Int = 302) -> Response {
            Response(status: status, headers: ["Location": location])
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "ccinn.test.loopback")
    private let captured = OSAllocatedUnfairLock(initialState: [Request]())
    private let connections = OSAllocatedUnfairLock(initialState: 0)

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Every request received so far, in order.
    var requests: [Request] { captured.withLock { $0 } }
    var paths: [String] { requests.map(\.path) }
    var connectionCount: Int { connections.withLock { $0 } }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        let handler = handler
        let queue = queue
        let captured = captured
        let connections = connections
        listener.newConnectionHandler = { connection in
            connections.withLock { $0 += 1 }
            connection.start(queue: queue)
            Self.receive(connection, buffer: Data(), queue: queue, handler: handler, captured: captured)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    guard !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, buffer: Data, queue: DispatchQueue, handler: @escaping Handler,
                                captured: OSAllocatedUnfairLock<[Request]>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil {
                    connection.cancel()
                } else {
                    receive(connection, buffer: buffer, queue: queue, handler: handler, captured: captured)
                }
                return
            }
            let request = parse(String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self))
            captured.withLock { $0.append(request) }
            let response = handler(request)
            let send: @Sendable () -> Void = {
                var head = "HTTP/1.1 \(response.status) \(HTTPHeaders.reasonPhrase(response.status))\r\n"
                for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
                head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
                let body = request.method == "HEAD" ? Data() : response.body
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
            if let delay = response.delay {
                let nanoseconds = delay.components.seconds * 1_000_000_000 + delay.components.attoseconds / 1_000_000_000
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: send)
            } else {
                send()
            }
        }
    }

    private static func parse(_ head: String) -> Request {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: requestLine.first.map(String.init) ?? "", path: requestLine.dropFirst().first.map(String.init) ?? "/",
                       headers: headers)
    }
}

extension LoopbackHTTPServer.Response {
    /// Serves `data` honouring a single `Range: bytes=a-b` / `bytes=a-` (206 + `Content-Range`), else 200 with the body.
    static func file(_ data: Data, type: String, for request: LoopbackHTTPServer.Request, headers: [String: String] = [:]) -> Self {
        var headers = headers.merging(["Content-Type": type, "Accept-Ranges": "bytes"]) { current, _ in current }
        guard let range = request.header("Range"), range.hasPrefix("bytes=") else {
            return Self(status: 200, headers: headers, body: data)
        }
        let bounds = range.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = bounds.first.flatMap({ Int($0) }), start < data.count else {
            headers["Content-Range"] = "bytes */\(data.count)"
            return Self(status: 416, headers: headers)
        }
        let requestedEnd = bounds.count > 1 ? Int(bounds[1]) : nil
        let end = min(requestedEnd ?? (data.count - 1), data.count - 1)
        headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
        return Self(status: 206, headers: headers, body: data.subdata(in: start..<(end + 1)))
    }
}
