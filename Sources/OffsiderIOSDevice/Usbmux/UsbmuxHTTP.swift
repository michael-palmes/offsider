import Foundation

public struct UsbmuxHTTPResponse: Equatable, Sendable {
    public let status: Int
    /// Header names in lowercase.
    public let headers: [String: String]
    public let body: Data
}

/// Just enough HTTP/1.1 for the device runner: one request per connection, `Content-Length` bodies, no chunking.
public enum UsbmuxHTTP {
    public static let maximumBody = 32 * 1024 * 1024
    static let maximumHead = 16 * 1024
    static let readChunk = 64 * 1024

    public static func request(method: String, path: String, token: String, body: Data?) -> Data {
        let body = body ?? Data()
        let head = [
            "\(method) \(path) HTTP/1.1",
            "Host: 127.0.0.1",
            "Content-Type: application/json",
            "X-Offsider-Token: \(token)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        return Data(head.utf8) + body
    }

    /// The complete response, nil while more bytes are needed.
    public static func parseResponse(_ data: Data) throws -> UsbmuxHTTPResponse? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maximumHead { throw UsbmuxError.malformed("an HTTP head over \(maximumHead) bytes") }
            return nil
        }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else {
            throw UsbmuxError.malformed("the HTTP status line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw UsbmuxError.malformed("an HTTP header line") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"].map({ $0.lowercased() != "identity" }) == true {
            throw UsbmuxError.malformed("a chunked HTTP body")
        }
        guard let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0, length <= maximumBody else {
            throw UsbmuxError.malformed("a missing or invalid Content-Length")
        }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        return UsbmuxHTTPResponse(status: status, headers: headers, body: Data(data[bodyStart..<(bodyStart + length)]))
    }

    /// Writes one request on a usbmux stream and reads its response; the socket's timeouts bound both.
    public static func exchange(on descriptor: Int32, method: String, path: String, token: String, body: Data?) throws -> UsbmuxHTTPResponse {
        try UsbmuxSocket.writeAll(request(method: method, path: path, token: token, body: body), to: descriptor)
        var received = Data()
        while true {
            if let response = try parseResponse(received) { return response }
            guard let chunk = try UsbmuxSocket.readSome(from: descriptor, limit: readChunk) else { throw UsbmuxError.closed }
            received.append(chunk)
        }
    }

    /// Bounds a stream from `UsbmuxClient.connect` before an exchange.
    public static func setTimeout(_ descriptor: Int32, seconds: TimeInterval) {
        UsbmuxSocket.setTimeouts(descriptor, seconds: seconds)
    }
}
