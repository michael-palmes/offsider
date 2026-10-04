import Foundation

/// Why a command failed; each reason fixes its exit code, so no site can pick one on its own.
public enum FailureReason: String, CaseIterable, Sendable {
    case commandFailed = "command_failed"
    case internalError = "internal_error"
    case inputFailed = "input_failed"
    case inputOutcomeUnknown = "input_outcome_unknown"
    case targetCovered = "target_covered"
    case targetUnderKeyboard = "target_under_keyboard"
    case targetHasNoFrame = "target_has_no_frame"
    case targetMoved = "target_moved"
    case notASlider = "not_a_slider"
    case sliderUnreadable = "slider_unreadable"
    case sliderUnverified = "slider_unverified"
    case noFocusedField = "no_focused_field"
    case fieldNotEditable = "field_not_editable"
    case unsupportedText = "unsupported_text"
    case securePasteRefused = "secure_paste_refused"
    case maskUnproven = "mask_unproven"
    case treeReadFailed = "tree_read_failed"
    case noWindow = "no_window"
    case screenNotIdle = "screen_not_idle"
    case screenshotFailed = "screenshot_failed"
    case baselineUnreadable = "baseline_unreadable"
    case baselineMismatch = "baseline_mismatch"
    case displayUnreadable = "display_unreadable"
    case displayOff = "display_off"
    case notSupported = "not_supported"
    case postureFailed = "posture_failed"
    case stateNotReached = "state_not_reached"
    case orientationUnknown = "orientation_unknown"
    case deviceRestarted = "device_restarted"
    case deviceUnresponsive = "device_unresponsive"
    case deviceControlFailed = "device_control_failed"
    case appNotInstalled = "app_not_installed"
    case logStreamFailed = "log_stream_failed"
    case videoFailed = "video_failed"
    case helperFailed = "helper_failed"
    case helperTimedOut = "helper_timed_out"
    case adbCommandFailed = "adb_command_failed"
    case adbProtocolError = "adb_protocol_error"
    case emulatorGrpcUnavailable = "emulator_grpc_unavailable"
    case emulatorGrpcAuthFailed = "emulator_grpc_auth_failed"
    case emulatorGrpcFailed = "emulator_grpc_failed"
    case emulatorTimedOut = "emulator_timed_out"
    case emulatorLaunchFailed = "emulator_launch_failed"
    case bootTimedOut = "boot_timed_out"
    case hidBrokerFailed = "hid_broker_failed"
    case privateDirectoryUnsafe = "private_directory_unsafe"
    case timedOut = "timed_out"
    case initFailed = "init_failed"
    case deviceListFailed = "device_list_failed"
    case expoDevClientFailed = "expo_dev_client_failed"

    case selectorNotFound = "selector_not_found"
    case selectorFilteredByType = "selector_filtered_by_type"
    case targetOffScreen = "target_off_screen"

    case notVerified = "not_verified"
    case conditionNotMet = "condition_not_met"

    case selectorAmbiguous = "selector_ambiguous"
    case selectorAmbiguousSwitch = "selector_ambiguous_switch"

    case deviceNotFound = "device_not_found"
    case deviceNotBooted = "device_not_booted"
    case deviceNotReady = "device_not_ready"
    case deviceUnauthorised = "device_unauthorised"
    case deviceAmbiguous = "device_ambiguous"
    case avdNotFound = "avd_not_found"

    case deviceBusy = "device_busy"
    case uiautomationBusy = "uiautomation_busy"

    case xcodeMissing = "xcode_missing"
    case xcodeUnusable = "xcode_unusable"
    case androidSdkMissing = "android_sdk_missing"
    case adbServerUnavailable = "adb_server_unavailable"
    case adbServerMisconfigured = "adb_server_misconfigured"
    case emulatorMissing = "emulator_missing"
    case emulatorGrpcRequired = "emulator_grpc_required"
    case helperUnavailable = "helper_unavailable"

    case usage
    case invalidDeviceID = "invalid_device_id"
    case invalidSetting = "invalid_setting"
    case unsupportedButton = "unsupported_button"
    case unsupportedKey = "unsupported_key"
    case unknownDisplay = "unknown_display"
    case legacyArgument = "legacy_argument"

    public var exitCode: OffsiderExitCode {
        switch self {
        case .selectorNotFound, .selectorFilteredByType, .targetOffScreen:
            return .selectorNotFound
        case .notVerified, .conditionNotMet:
            return .unverified
        case .selectorAmbiguous, .selectorAmbiguousSwitch:
            return .ambiguousSelector
        case .deviceNotFound, .deviceNotBooted, .deviceNotReady, .deviceUnauthorised, .deviceAmbiguous, .avdNotFound:
            return .deviceUnavailable
        case .deviceBusy, .uiautomationBusy:
            return .deviceBusy
        case .xcodeMissing, .xcodeUnusable, .androidSdkMissing, .adbServerUnavailable, .adbServerMisconfigured,
             .emulatorMissing, .emulatorGrpcRequired, .helperUnavailable:
            return .toolMissing
        case .usage, .invalidDeviceID, .invalidSetting, .unsupportedButton, .unsupportedKey, .unknownDisplay, .legacyArgument:
            return .usage
        default:
            return .failure
        }
    }
}
