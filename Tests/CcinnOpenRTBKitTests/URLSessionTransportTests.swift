import Foundation
import Network
import os
import RTBKit
import Testing
@testable import CcinnOpenRTBKit

/// A tiny HTTP/1.1 server on 127.0.0.1 with fixed routes, to test the real transport without the internet.
final class LocalHTTPServer: Sendable {
    struct Route: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private let listener: NWListener
    private let routes: [String: Route]
    private let queue = DispatchQueue(label: "ccinn.test.http")
    private let seen = OSAllocatedUnfairLock(initialState: [String]())

    init(routes: [String: Route]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Paths and the User-Agent of every request, in order.
    var requests: [String] { seen.withLock { $0 } }

    func start() async throws -> UInt16 {
        let routes = routes
        let queue = queue
        let seen = seen
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.serve(connection, routes: routes, seen: seen, buffer: Data())
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

    func stop() {
        listener.cancel()
    }

    private static func serve(_ connection: NWConnection, routes: [String: Route], seen: OSAllocatedUnfairLock<[String]>, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { serve(connection, routes: routes, seen: seen, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let agent = lines.first { $0.lowercased().hasPrefix("user-agent:") }.map { String($0.dropFirst(11)).trimmingCharacters(in: .whitespaces) } ?? ""
            seen.withLock { $0.append("\(path) \(agent)") }
            let route = routes[path] ?? Route(status: 404, headers: [:], body: Data("not found".utf8))
            var response = "HTTP/1.1 \(route.status) \(HTTPHeaders.reasonPhrase(route.status))\r\n"
            for (name, value) in route.headers { response += "\(name): \(value)\r\n" }
            response += "Content-Length: \(route.body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + route.body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite("URLSession transport", .serialized)
struct URLSessionTransportTests {
    @Test func doesNotFollowRedirectsAndCapsBodies() async throws {
        let server = try LocalHTTPServer(routes: [
            "/imp": .init(status: 302, headers: ["Location": "/final"], body: Data("moved".utf8)),
            "/final": .init(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("ok".utf8)),
            "/big": .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: Data(count: 300_000)),
        ])
        let port = try await server.start()
        defer { server.stop() }
        let transport = URLSessionTransport()
        let base = "http://127.0.0.1:\(port)"

        let redirect = try await transport.perform(HTTPRequest(url: try #require(URL(string: base + "/imp")),
                                                               headers: ["User-Agent": deviceUA], timeout: 10, maxBodyBytes: 1_024))
        #expect(redirect.status == 302)
        #expect(redirect.location == "/final")
        #expect(String(decoding: redirect.body, as: UTF8.self) == "moved")
        #expect(server.requests == ["/imp \(deviceUA)"], "the transport must not follow the redirect")

        let big = try await transport.perform(HTTPRequest(url: try #require(URL(string: base + "/big")), timeout: 10, maxBodyBytes: 1_000))
        #expect(big.truncated)
        #expect(big.body.count == 1_000)
        #expect(big.timings != nil)
    }

    @Test func monitorFollowsTheRealChainAndRecordsEveryHop() async throws {
        let server = try LocalHTTPServer(routes: [
            "/imp": .init(status: 302, headers: ["Location": "/final"], body: Data()),
            "/final": .init(status: 204, headers: [:], body: Data()),
        ])
        let port = try await server.start()
        defer { server.stop() }
        let monitor = await MainActor.run {
            NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        }
        let id = await MainActor.run {
            monitor.mode = .real
            return monitor.dispatch(tracker(.impression, "http://127.0.0.1:\(port)/imp"), userAgent: deviceUA)
        }
        await monitor.waitUntilIdle()
        let recorded = await monitor.liveEntries
        #expect(recorded.count == 2)
        #expect(recorded.first?.id == id)
        #expect(recorded.first?.state == .completed(status: 302))
        #expect(recorded.last?.state == .completed(status: 204))
        #expect(recorded.last?.redirectLocation == "/final")
        #expect(server.requests == ["/imp \(deviceUA)", "/final \(deviceUA)"])
    }

    @Test func cancellationStopsTheRequest() async throws {
        let transport = URLSessionTransport()
        // A non-routable address: the request hangs until it is cancelled.
        let task = Task {
            try await transport.perform(HTTPRequest(url: try #require(URL(string: "http://10.255.255.1:81/x")), timeout: 30, maxBodyBytes: 10))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
    }

    /// A task that completes before `start` stored the continuation still resumes (no hang).
    @Test func completionBeforeStartStillResumes() async throws {
        let exchange = Exchange(maxBodyBytes: 10)
        let task = URLSession.shared.dataTask(with: URL(fileURLWithPath: "/nonexistent"))
        exchange.complete(URLError(.cancelled))
        await #expect(throws: URLError.self) {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                exchange.start(task, continuation: continuation)
            }
        }
    }

    /// Hitting the cap cancels the task; the cancellation then completes as a truncated success, not as an error.
    @Test func bodyCapKeepsExactlyTheLimit() async throws {
        let exchange = Exchange(maxBodyBytes: 5)
        exchange.receive(try #require(HTTPURLResponse(url: URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: nil, headerFields: nil)))
        #expect(exchange.append(Data("abc".utf8)))
        #expect(!exchange.append(Data("defgh".utf8)))
        exchange.complete(URLError(.cancelled))
        let task = URLSession.shared.dataTask(with: URL(fileURLWithPath: "/nonexistent"))
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
            exchange.start(task, continuation: continuation)
        }
        #expect(response.truncated)
        #expect(response.body == Data("abcde".utf8))
    }
}
