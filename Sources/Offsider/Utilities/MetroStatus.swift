import Foundation

/// Asks Metro on this Mac whether it is running, at `http://127.0.0.1:<port>/status`; the host is fixed to loopback.
struct MetroStatus {
    typealias Fetch = @Sendable (URL, TimeInterval) async throws -> (status: Int, body: Data)

    static let host = "127.0.0.1"
    static let timeout: TimeInterval = 2
    /// Metro's own answer to `/status`.
    static let runningBody = "packager-status:running"

    var fetch: Fetch = MetroStatus.liveFetch

    static func url(port: Int) -> URL {
        URL(string: "http://\(host):\(port)/status")!
    }

    /// Nil when Metro answers as running; otherwise why not, for the error.
    func problem(port: Int) async -> String? {
        do {
            let (status, body) = try await fetch(Self.url(port: port), Self.timeout)
            guard status == 200 else { return "it answered HTTP \(status)" }
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text == Self.runningBody ? nil : "something else answered on that port"
        } catch {
            return "nothing answered within \(Int(Self.timeout)) s"
        }
    }

    static let liveFetch: Fetch = { url, timeout in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
