import Foundation

extension CoreDeviceErrorInfo {
    /// The `error` block `devicectl --json-output -` writes when a command fails; nil when `stdout` holds none.
    public init?(devicectlOutput stdout: String) {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        self.init(devicectlError: error)
    }

    /// An underlying error is nested as `{ "error": { ... } }` and a string as `{ "string": "..." }`; plain forms are read too.
    private init?(devicectlError error: [String: Any]) {
        guard let domain = error["domain"] as? String, let code = error["code"] as? Int else { return nil }
        let info = error["userInfo"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String? {
            (info[key] as? String) ?? ((info[key] as? [String: Any])?["string"] as? String)
        }
        func nested(_ value: Any?) -> CoreDeviceErrorInfo? {
            guard let value = value as? [String: Any] else { return nil }
            return CoreDeviceErrorInfo(devicectlError: value["error"] as? [String: Any] ?? value)
        }
        let many = info["NSMultipleUnderlyingErrorsKey"]
        self.init(
            domain: domain,
            code: code,
            description: text("NSLocalizedDescription") ?? text("NSLocalizedFailureReason"),
            underlying: (nested(info["NSUnderlyingError"]).map { [$0] } ?? [])
                + ((many as? [Any]) ?? ((many as? [String: Any])?["array"] as? [Any]) ?? []).compactMap(nested)
        )
    }
}
