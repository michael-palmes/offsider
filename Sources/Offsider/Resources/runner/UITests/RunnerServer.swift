import Foundation
import Network

struct RunnerRequest {
    let method: String
    let path: String
    /// Names in lowercase.
    let headers: [String: String]
    let body: Data
}

struct RunnerResponse {
    let status: Int
    let body: Data

    static func ok(_ data: Any) -> RunnerResponse {
        envelope(200, ["ok": true, "data": data])
    }

    static func failure(_ status: Int, code: String, message: String) -> RunnerResponse {
        envelope(status, ["ok": false, "error": ["code": code, "message": message]])
    }

    private static func envelope(_ status: Int, _ object: [String: Any]) -> RunnerResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("{\"ok\":false}".utf8)
        return RunnerResponse(status: status, body: body)
    }
}

/// HTTP/1.1 with `Content-Length` bodies only, one request per connection.
enum RunnerHTTP {
    enum Parsed {
        case needMore
        case invalid(String)
        case request(RunnerRequest)
    }

    static let maximumHead = 16 * 1024
    static let maximumBody = 1024 * 1024

    static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHead ? .invalid("head too large") : .needMore
        }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid("bad request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header line") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid("chunked bodies are not accepted") }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...maximumBody).contains(length) else { return .invalid("bad Content-Length") }
        let start = end.upperBound
        guard data.distance(from: start, to: data.endIndex) >= length else { return .needMore }
        let body = Data(data[start..<data.index(start, offsetBy: length)])
        return .request(RunnerRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body))
    }

    static func encode(_ response: RunnerResponse) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 422: "Unprocessable Content"][response.status] ?? "Error"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}

/// Listens on 127.0.0.1 only; usbmuxd reaches it from the Mac, nothing on the network can.
final class RunnerServer {
    private let token: String
    private let handler: (RunnerRequest) -> RunnerResponse
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.mpalmes.offsider.runner.server")

    init(port: UInt16, token: String, handler: @escaping (RunnerRequest) -> RunnerResponse) throws {
        self.token = token
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
    }

    /// `ready` runs once with the bound port, `failed` if the listener cannot bind.
    func start(ready: @escaping (UInt16) -> Void, failed: @escaping (String) -> Void) {
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: ready(listener.port?.rawValue ?? 0)
            case .failed(let error): failed("\(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch RunnerHTTP.parse(buffer) {
            case .needMore:
                if isComplete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
            case .invalid(let message):
                self.send(.failure(400, code: "bad_request", message: message), on: connection)
            case .request(let request):
                guard request.headers["x-offsider-token"] == self.token else {
                    return self.send(.failure(401, code: "unauthorised", message: "missing or wrong X-Offsider-Token"), on: connection)
                }
                DispatchQueue.main.async {
                    let response = self.handler(request)
                    self.queue.async { self.send(response, on: connection) }
                }
            }
        }
    }

    private func send(_ response: RunnerResponse, on connection: NWConnection) {
        connection.send(content: RunnerHTTP.encode(response), completion: .contentProcessed { _ in connection.cancel() })
    }
}
