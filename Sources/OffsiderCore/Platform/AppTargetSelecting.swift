import Foundation

/// Optional capability: a phone's backend reads and drives only the app a command names, checked in front before every frame and input.
@MainActor
public protocol AppTargetSelecting: DeviceBackend {
    /// True when the app this command drives changed.
    @discardableResult
    func selectApp(_ appID: String, on id: DeviceID) -> Bool
}
