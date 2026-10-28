import Foundation
import OffsiderCore

/// Asks Metro on this Mac whether it is running, at `http://127.0.0.1:<port>/status`; the host is fixed to loopback.
struct MetroStatus {
    typealias Fetch = @Sendable (URL, TimeInterval) async throws -> (status: Int, body: Data)

    static let host = "127.0.0.1"
    static let timeout: TimeInterval = 2
    /// Metro's own answer to `/status`.
    static let runningBody = "packager-status:running"

    var fetch: Fetch = MetroStatus.liveFetch
    /// Whether a process of this user accepts connections to 127.0.0.1 on the port, as it must before `rn open` maps a phone to it.
    var ownedByThisUser: @Sendable (Int) async -> Bool = MetroStatus.liveOwned

    static func url(port: Int) -> URL {
        URL(string: "http://\(host):\(port)/status")!
    }

    /// Nil when Metro answers as running; otherwise why not, for the error.
    func problem(port: Int) async -> String? {
        do {
            let (status, body) = try await fetch(Self.url(port: port), Self.timeout)
            if (300...399).contains(status) { return "something else answered on that port (it redirected)" }
            guard status == 200 else { return "it answered HTTP \(status)" }
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text == Self.runningBody ? nil : "something else answered on that port"
        } catch {
            return "nothing answered within \(Int(Self.timeout)) s"
        }
    }

    static let liveOwned: @Sendable (Int) async -> Bool = { port in
        await Task.detached { LoopbackOwner.acceptedByUser(port: port) }.value
    }

    static let liveFetch: Fetch = { url, timeout in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Never follows a redirect, so the check stays on loopback; the 3xx itself comes back as the answer.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
