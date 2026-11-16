import Foundation
import os

/// `HTTPTransport` over an ephemeral `URLSession` (no cookies, no cache, no credentials) whose delegate refuses every
/// redirect, so a 3xx comes back as the response and the monitor records each hop itself. Bodies are read up to
/// `maxBodyBytes` and then the task is cancelled (`truncated`). Phase timings come from `URLSessionTaskMetrics`.
public final class URLSessionTransport: HTTPTransport {
    public static let shared = URLSessionTransport()

    private let session: URLSession
    private let delegate: TransportDelegate

    public init(configuration: URLSessionConfiguration = URLSessionTransport.defaultConfiguration()) {
        delegate = TransportDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return configuration
    }

    public func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(1, request.timeout))
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: urlRequest)
        let exchange = Exchange(maxBodyBytes: request.maxBodyBytes)
        delegate.register(exchange, for: task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                exchange.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// One request's state, guarded by its own lock (the delegate only takes the registry lock to find it).
final class Exchange: Sendable {
    private struct State {
        var continuation: CheckedContinuation<HTTPResponse, any Error>?
        var response: HTTPURLResponse?
        var body = Data()
        var truncated = false
        var timings: HTTPTimings?
        /// The task finished before `start` stored the continuation.
        var outcome: Result<HTTPResponse, any Error>?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    let maxBodyBytes: Int

    init(maxBodyBytes: Int) {
        self.maxBodyBytes = maxBodyBytes
    }

    func start(_ task: URLSessionTask, continuation: CheckedContinuation<HTTPResponse, any Error>) {
        let finished = state.withLockUnchecked { state -> Result<HTTPResponse, any Error>? in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        if let finished {
            continuation.resume(with: finished)
        } else {
            task.resume()
        }
    }

    func receive(_ response: URLResponse) {
        state.withLockUnchecked { $0.response = response as? HTTPURLResponse }
    }

    /// Appends body bytes; `false` once the cap is reached (the caller cancels the task).
    func append(_ data: Data) -> Bool {
        state.withLockUnchecked { state in
            let room = maxBodyBytes - state.body.count
            if data.count <= room {
                state.body.append(data)
                return true
            }
            if room > 0 { state.body.append(data.prefix(room)) }
            state.truncated = true
            return false
        }
    }

    func collect(_ metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        let timings = Self.timings(transaction, interval: metrics.taskInterval)
        state.withLockUnchecked { $0.timings = timings }
    }

    func complete(_ error: (any Error)?) {
        let (continuation, outcome) = state.withLockUnchecked { state -> (CheckedContinuation<HTTPResponse, any Error>?, Result<HTTPResponse, any Error>) in
            let outcome: Result<HTTPResponse, any Error>
            if let response = state.response, error == nil || state.truncated {
                outcome = .success(HTTPResponse(status: response.statusCode, headers: Self.headers(response), body: state.body,
                                                truncated: state.truncated, timings: state.timings))
            } else {
                outcome = .failure(error ?? URLError(.badServerResponse))
            }
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil { state.outcome = outcome }
            return (continuation, outcome)
        }
        continuation?.resume(with: outcome)
    }

    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }

    static func timings(_ transaction: URLSessionTaskTransactionMetrics, interval: DateInterval) -> HTTPTimings {
        func milliseconds(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return max(0, end.timeIntervalSince(start) * 1000)
        }
        let fetchStart = transaction.fetchStartDate ?? interval.start
        let dns = milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        let connect = milliseconds(transaction.connectStartDate, transaction.connectEndDate)
        let ssl = milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        let blocked = milliseconds(fetchStart, transaction.domainLookupStartDate ?? transaction.connectStartDate ?? transaction.requestStartDate)
        let send = milliseconds(transaction.requestStartDate, transaction.requestEndDate) ?? 0
        let wait = milliseconds(transaction.requestEndDate, transaction.responseStartDate) ?? 0
        let receive = milliseconds(transaction.responseStartDate, transaction.responseEndDate) ?? 0
        return HTTPTimings(blocked: blocked, dns: dns, connect: connect, ssl: ssl, send: send, wait: wait, receive: receive)
    }
}

/// Session delegate: routes callbacks to the request's `Exchange` and never follows a redirect.
final class TransportDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let exchanges = OSAllocatedUnfairLock(initialState: [Int: Exchange]())

    func register(_ exchange: Exchange, for task: URLSessionTask) {
        exchanges.withLock { $0[task.taskIdentifier] = exchange }
    }

    private func exchange(for task: URLSessionTask) -> Exchange? {
        exchanges.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // The monitor follows redirects itself, recording each hop.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        exchange(for: dataTask)?.receive(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask) else { return }
        if !exchange.append(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        exchange(for: task)?.collect(metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let exchange = exchanges.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        exchange?.complete(error)
    }
}
