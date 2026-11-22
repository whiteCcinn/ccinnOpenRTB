import Foundation

/// Update traffic is https on every hop: the first request and each redirect.
///
/// The app allows cleartext (`NSAllowsArbitraryLoads` in `Resources/Info.plist`) because the endpoints, trackers and
/// media it simulates are often plain http, so App Transport Security no longer guarantees this for the updater. The
/// release metadata, its `SHA256SUMS.txt` and the disk image all come from GitHub: were they fetched over http, one
/// on-path attacker could replace the image and its checksum together.
enum UpdateTransport {
    static func isSecure(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
    }

    /// The redirect to follow; `nil` refuses it, and the 3xx becomes the answer.
    static func follow(_ request: URLRequest) -> URLRequest? {
        isSecure(request.url) ? request : nil
    }

    /// The reason a 3xx was not followed (its `Location` is not https); `nil` for anything else, whose status speaks
    /// for itself.
    static func refusedRedirect(_ response: HTTPURLResponse) -> UpdateError? {
        guard (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: response.url)?.absoluteURL,
              !isSecure(target) else { return nil }
        return refused(target, redirected: true)
    }

    /// Only the scheme and host are named: the rest of a URL may carry signed tokens.
    static func refused(_ url: URL?, redirected: Bool) -> UpdateError {
        let address = url.map { "\($0.scheme ?? "?")://\($0.host ?? "")" } ?? "an address without a scheme"
        let what = redirected ? "Redirected to \(address)" : "Refused \(address)"
        return UpdateError(.network, "\(what): updates are fetched over https only.")
    }
}

/// Session delegate of `URLSessionUpdateClient`: follows a redirect only to https (`UpdateTransport.follow`).
final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(UpdateTransport.follow(request))
    }
}
