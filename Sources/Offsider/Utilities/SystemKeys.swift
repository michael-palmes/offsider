import ArgumentParser
import Foundation
import OffsiderCore

/// `--allow-system-keys` on the key commands and their batch steps.
struct SystemKeyOptions: ParsableArguments {
    @Flag(name: .customLong("allow-system-keys"), help: "On a physical Android phone, send Meta (227 or 231) anyway; phones take Meta combinations as system shortcuts, so it is refused without this.")
    var allowSystemKeys = false

    /// A usage error (exit 64) before anything is sent when `keys` hold Meta and `device` is an Android phone.
    func check(_ keys: [Int], on device: DeviceID) throws {
        guard let message = SystemKeyGuard.refusal(keys: keys, on: device, allowed: allowSystemKeys) else { return }
        throw CLIError(errorDescription: message, reason: .usage)
    }
}
