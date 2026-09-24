import Foundation

/// Stable check ids: scripts and agents match on these raw values.
public enum DoctorCheckID: String, Codable, Sendable, CaseIterable {
    case developerDir = "xcode.developer-dir"
    case xcodeVersion = "xcode.version"
    case frameworks = "xcode.frameworks"
    case coreSimulator = "coresimulator.version"
    case simulatorApp = "host.simulator-app"
    case deviceHub = "host.device-hub"
    case stabilization = "hid.stabilization"
    case brokerDirectory = "hid.broker-dir"
    case bootedSimulators = "simulators.booted"
    case simulatorState = "simulator.state"
    case deviceWindow = "simulator.device-window"
    case resizeMode = "simulator.resize-mode"
    case dtuhidd = "simulator.dtuhidd"
    case dtuhidActiveFlag = "simulator.dtuhidd-active-flag"
    case hidTransport = "simulator.hid-transport"
    case accessibility = "simulator.accessibility"

    public var isPerSimulator: Bool {
        rawValue.hasPrefix("simulator.")
    }

    public var title: String {
        switch self {
        case .developerDir: return "Xcode developer directory"
        case .xcodeVersion: return "Xcode version"
        case .frameworks: return "Simulator frameworks"
        case .coreSimulator: return "CoreSimulator version"
        case .simulatorApp: return "Simulator.app"
        case .deviceHub: return "Device Hub"
        case .stabilization: return "HID stabilisation delay"
        case .brokerDirectory: return "HID broker directory"
        case .bootedSimulators: return "Booted simulators"
        case .simulatorState: return "Simulator state"
        case .deviceWindow: return "Device window"
        case .resizeMode: return "Resize Mode"
        case .dtuhidd: return "dtuhidd process"
        case .dtuhidActiveFlag: return "dtuhidd active flag"
        case .hidTransport: return "HID transport"
        case .accessibility: return "Accessibility"
        }
    }
}
