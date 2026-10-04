import Foundation

extension PlatformUnavailable: OffsiderFailure {
    public var reason: FailureReason { platform == .ios ? .xcodeMissing : .androidSdkMissing }
    public var failureMessage: String { message }
    public var hint: String? { platform == .ios ? "xcode-select -s <Xcode.app>/Contents/Developer" : nil }
}

extension WaitUnreadableError: OffsiderFailure {
    public var reason: FailureReason { .treeReadFailed }
    public var failureMessage: String { description }
}

extension ImageFailure: OffsiderFailure {
    public var reason: FailureReason { .screenshotFailed }
    public var failureMessage: String { description }
}

extension MaskUnproven: OffsiderFailure {
    public var reason: FailureReason { .maskUnproven }
    public var failureMessage: String { description }
}

extension ProcessCaptureTimeoutError: OffsiderFailure {
    public var reason: FailureReason { .timedOut }
    public var failureMessage: String { description }
}

extension ExpoDevClientError: OffsiderFailure {
    public var reason: FailureReason { .expoDevClientFailed }
    public var failureMessage: String { description }
}

extension DeviceSettingsError: OffsiderFailure {
    public var reason: FailureReason { .deviceControlFailed }
    public var failureMessage: String { description }
}

extension ScreenRegionError: OffsiderFailure {
    public var reason: FailureReason { .usage }
    public var failureMessage: String { description }
}

extension UIFieldError: OffsiderFailure {
    public var reason: FailureReason { .usage }
    public var failureMessage: String { description }
}

extension LogOptionError: OffsiderFailure {
    public var reason: FailureReason { .usage }
    public var failureMessage: String { message }
}
