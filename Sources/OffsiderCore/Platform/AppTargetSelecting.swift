import Foundation

/// Optional capability: a phone's backend reads and drives only the app a command names, checked in front before every input, and at most every 1 s on Android or 2 s on an iPhone for video frames.
@MainActor
public protocol AppTargetSelecting: DeviceBackend {
    /// True when the app this command drives changed.
    @discardableResult
    func selectApp(_ appID: String, on id: DeviceID) -> Bool
    /// The app this command drives, when one is named.
    func selectedApp(on id: DeviceID) -> String?
}
