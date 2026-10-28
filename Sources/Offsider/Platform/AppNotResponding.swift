import Foundation
import OffsiderCore

/// Android lists no window for an app whose main thread is stuck, so a tree read finds none although the app is in front on a usable screen.
enum AppNotResponding {
    /// The package in front when the screen is on and unlocked and it is not the home screen; nil when a read fails or the screen is not usable.
    @MainActor
    static func frontApp(on route: DeviceRouter.Route, awake known: AwakeReading? = nil) async -> String? {
        guard route.device.platform == .android, let foreground = route.backend as? any ForegroundReading else { return nil }
        let reading: AwakeReading? = if let known { known } else { try? await (route.backend as? any AwakeControlling)?.awakeState(on: route.device) }
        guard reading?.isUsable == true, let front = try? await foreground.foreground(on: route.device), let top = front.top else { return nil }
        let package = Self.package(of: top)
        return front.home.map(Self.package(of:)) == package ? nil : package
    }

    /// For any command whose read found no window: the app may still be starting, so the message says both.
    static func failure(package: String, device: DeviceID) -> CLIError {
        CLIError(
            errorDescription: "\(package) is in front on \(device.rawValue), but Android lists no window for it, so the app is not responding or still starting. Wait a moment and retry; if it lasts, close the app and open it again.",
            reason: .appNotResponding
        )
    }

    private static func package(of component: String) -> String {
        String(component.split(separator: "/").first ?? Substring(component))
    }
}
