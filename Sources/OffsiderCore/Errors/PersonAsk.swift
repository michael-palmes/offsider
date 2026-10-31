import Foundation

/// What an agent asks the user when only their hands can clear a failure: the step and the device, as a request.
public enum PersonAsk {
    /// Stands for the device in an ask until the failure is reported.
    public static let devicePlaceholder = "<DEVICE_NAME>"
    public static let maximumNameLength = 60

    public static let tickTurnstile = "Can you tick the Turnstile checkbox on \(devicePlaceholder)?"
    public static let tickTurnstiles = "Can you tick the Turnstile checkboxes on \(devicePlaceholder)?"
    public static let solveTurnstile = "Can you solve the Turnstile challenge on \(devicePlaceholder)?"
    public static let finishTurnstile = "Can you finish the Turnstile check on \(devicePlaceholder)?"

    /// `ask` naming the device by its name, else its id, else in plain words. A name can come from the device, so it is cleaned and capped.
    public static func filled(_ ask: String, name: String?, id: String?) -> String {
        let known = [name, id].lazy
            .compactMap { $0.map { TerminalText.line($0, cap: maximumNameLength, keepsTab: false) } }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ask.replacingOccurrences(of: devicePlaceholder, with: known ?? "the device")
    }

    /// The name a person knows `id` by; another running device with that name adds its OS, or failing that the id.
    public static func name(of id: String, among devices: [DeviceSummary]) -> String? {
        guard let device = devices.first(where: { $0.id == id }) else { return nil }
        let twins = devices.filter { $0.id != id && $0.name == device.name && $0.state == "Booted" }
        guard !twins.isEmpty else { return device.name }
        if let os = device.osVersion, !twins.contains(where: { $0.osVersion == os }) {
            return "\(device.name) on \(os)"
        }
        return "\(device.name) (\(id))"
    }
}

extension FailureReason {
    /// The ask for a failure only a person's hands can clear; nil for the rest.
    public var personAsk: String? {
        let device = PersonAsk.devicePlaceholder
        switch self {
        case .turnstileRequired: return PersonAsk.tickTurnstile
        case .deviceLocked: return "Can you unlock \(device)?"
        case .deviceUntrusted: return "Can you unlock \(device) and tap Trust?"
        case .developerModeOff: return "Can you turn on Developer Mode on \(device) and restart it?"
        case .uiAutomationOff: return "Can you turn on Settings > Developer > UI Automation on \(device), or enter the passcode on the device if it asks for XCTest?"
        case .deviceNotWired: return "Can you connect \(device) with a cable?"
        case .usbmuxUnavailable: return "Can you unplug and replug the cable on \(device)?"
        default: return nil
        }
    }
}
