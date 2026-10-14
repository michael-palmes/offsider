import Foundation
import OffsiderCore

/// `pm list packages -3`: one `package:<name>` line per app a person installed.
enum AndroidPackageList {
    static let command = "pm list packages -3"

    static func parse(_ output: String) -> [String] {
        let names = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("package:") else { return nil }
            let name = String(text.dropFirst("package:".count))
            return DeviceAllowance.isAppID(name) ? name : nil
        }
        return Array(Set(names)).sorted()
    }
}

extension AndroidBackend {
    /// The third-party packages on a USB phone, sorted; one shell query.
    public func thirdPartyPackages(serial: String) async throws -> [String] {
        try await prepare()
        _ = try await requireConnectedPhone(serial)
        let result = try await requireClient().shell(AndroidPackageList.command, on: serial)
        guard result.status == 0 else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidError.adbCommandFailed(serial: serial, command: AndroidPackageList.command, detail: detail.isEmpty ? "exit \(result.status)" : detail)
        }
        return AndroidPackageList.parse(result.stdoutText)
    }
}
