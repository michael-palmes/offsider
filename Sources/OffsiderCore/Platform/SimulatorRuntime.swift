import Foundation

public enum SimulatorRuntime {
    private static let iosIdentifierPrefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
    private static let iosNamePrefix = "iOS "

    /// iPad simulators run the iOS runtime too; the OS name is the fallback when CoreSimulator gives no identifier.
    public static func isIOS(runtimeIdentifier: String?, osVersionName: String) -> Bool {
        if let runtimeIdentifier, !runtimeIdentifier.isEmpty {
            return runtimeIdentifier.hasPrefix(iosIdentifierPrefix)
        }
        return osVersionName.hasPrefix(iosNamePrefix)
    }
}
