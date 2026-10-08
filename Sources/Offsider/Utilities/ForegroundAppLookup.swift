import Foundation
import OffsiderCore

/// Reads the foreground app id and turns a miss into a `CLIError` that names no secret and no file path.
enum ForegroundAppLookup {
    static func identifier(in tree: UITree, forLogin: Bool) throws -> String {
        do {
            return try ForegroundApp.identifier(in: tree, pathForPID: { pid in
                guard let pid = Int32(exactly: pid) else { return nil }
                return ProcessPath.of(pid: pid)
            })
        } catch let failure as ForegroundApp.Failure {
            throw error(failure, forLogin: forLogin)
        }
    }

    static func error(_ failure: ForegroundApp.Failure, forLogin: Bool) -> CLIError {
        let suffix = forLogin ? " Nothing was typed." : ""
        switch failure {
        case .notInFront:
            let message = forLogin
                ? "No app is in front.\(suffix)"
                : "No app is in front. Pass --app with its bundle id or package, such as com.example.app."
            return CLIError(errorDescription: message, reason: forLogin ? .selectorNotFound : .usage)
        case .unreadableExecutable:
            let message = forLogin
                ? "The app in front has no readable executable, so its bundle id cannot be read.\(suffix)"
                : "The app in front has no readable executable, so its bundle id cannot be read. Pass --app, such as com.example.app."
            return CLIError(errorDescription: message, reason: .commandFailed)
        case .missingBundleIdentifier:
            let message = forLogin
                ? "The app in front has no bundle id.\(suffix)"
                : "The app in front has no bundle id. Pass --app, such as com.example.app."
            return CLIError(errorDescription: message, reason: .commandFailed)
        case .severalPackages(let packages):
            let listed = packages.joined(separator: ", ")
            let message = forLogin
                ? "Several apps are in front (\(listed)).\(suffix)"
                : "Several apps are in front (\(listed)). Pass --app for the one you want, such as com.example.app."
            return CLIError(errorDescription: message, reason: .selectorAmbiguous)
        }
    }
}
