import Foundation
import OffsiderCore

extension TextToHIDEvents.TextConversionError: OffsiderFailure {
    var reason: FailureReason { .unsupportedText }
    var failureMessage: String { userFacingDescription }
}

extension HIDBrokerNotReadyError: OffsiderFailure {
    var reason: FailureReason { .hidBrokerFailed }
    var failureMessage: String { userFacingDescription }
    var hint: String? { "offsider doctor --device <DEVICE_ID>" }
}

extension VideoProcessingError: OffsiderFailure {
    var reason: FailureReason { .videoFailed }
    var failureMessage: String { userFacingDescription }
}

extension SimulatorDTUHID.Failure: OffsiderFailure {
    var reason: FailureReason { .inputFailed }
    var failureMessage: String { description }
    var hint: String? { "offsider doctor --device <DEVICE_ID>" }
}

extension ShellTokenizer.TokenizerError: OffsiderFailure {
    var reason: FailureReason { .usage }
    var failureMessage: String { userFacingDescription }
}

extension Tap: JSONReportingCommand { var wantsJSON: Bool { verification.json } }
extension Type: JSONReportingCommand { var wantsJSON: Bool { verification.json } }
extension Key: JSONReportingCommand { var wantsJSON: Bool { verification.json } }
extension Button: JSONReportingCommand { var wantsJSON: Bool { verification.json } }
extension Screenshot: JSONReportingCommand { var wantsJSON: Bool { json } }
extension Wait: JSONReportingCommand { var wantsJSON: Bool { json } }
extension Assert: JSONReportingCommand { var wantsJSON: Bool { json } }
extension Logs: JSONReportingCommand { var wantsJSON: Bool { json } }
extension Doctor: JSONReportingCommand { var wantsJSON: Bool { json } }
extension ContentSizeCommand: JSONReportingCommand { var wantsJSON: Bool { json } }
extension PostureCommand: JSONReportingCommand { var wantsJSON: Bool { json } }
extension OrientationCommand: JSONReportingCommand { var wantsJSON: Bool { json } }
extension ListDevices: JSONReportingCommand { var wantsJSON: Bool { json } }
extension Batch: JSONReportingCommand { var wantsJSON: Bool { json } }
extension Displays: JSONReportingCommand { var wantsJSON: Bool { json } }
extension AppearanceCommand: JSONReportingCommand { var wantsJSON: Bool { json } }
extension DescribeUI: JSONReportingCommand { var wantsJSON: Bool { output.writesJSON } }
