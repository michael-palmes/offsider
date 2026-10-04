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
    case simulatorCrashLoops = "simulators.crash-loop"
    case simulatorState = "simulator.state"
    case deviceWindow = "simulator.device-window"
    case resizeMode = "simulator.resize-mode"
    case dtuhidd = "simulator.dtuhidd"
    case dtuhidActiveFlag = "simulator.dtuhidd-active-flag"
    case hidTransport = "simulator.hid-transport"
    case accessibility = "simulator.accessibility"
    case crashLoop = "simulator.crash-loop"
    case androidSDK = "android.sdk"
    case androidAdb = "android.adb"
    case androidAdbServer = "android.adb-server"
    case androidAdbMDNS = "android.adb-mdns"
    case androidEmulator = "android.emulator"
    case androidHelperBundle = "android.helper-bundle"
    case androidDevices = "android.devices"
    case androidDeviceState = "android-device.state"
    case androidDeviceImage = "android-device.image"
    case androidDeviceGrpc = "android-device.grpc"
    case androidDeviceUiAutomation = "android-device.uiautomation"
    case androidDeviceHelper = "android-device.helper"
    case androidDeviceMetroReverse = "android-device.metro-reverse"

    public var isPerSimulator: Bool {
        rawValue.hasPrefix("simulator.")
    }

    public var isAndroidHost: Bool {
        rawValue.hasPrefix("android.")
    }

    public var isPerAndroidDevice: Bool {
        rawValue.hasPrefix("android-device.")
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
        case .simulatorCrashLoops: return "Simulator crash loops"
        case .simulatorState: return "Simulator state"
        case .deviceWindow: return "Device window"
        case .resizeMode: return "Resize Mode"
        case .dtuhidd: return "dtuhidd process"
        case .dtuhidActiveFlag: return "dtuhidd active flag"
        case .hidTransport: return "HID transport"
        case .accessibility: return "Accessibility"
        case .crashLoop: return "Crash loop"
        case .androidSDK: return "Android SDK"
        case .androidAdb: return "adb"
        case .androidAdbServer: return "adb server"
        case .androidAdbMDNS: return "adb mDNS"
        case .androidEmulator: return "Android Emulator"
        case .androidHelperBundle: return "Android helper bundle"
        case .androidDevices: return "Android devices"
        case .androidDeviceState: return "Device state"
        case .androidDeviceImage: return "System image"
        case .androidDeviceGrpc: return "Emulator gRPC"
        case .androidDeviceUiAutomation: return "UiAutomation"
        case .androidDeviceHelper: return "UiAutomation helper"
        case .androidDeviceMetroReverse: return "Metro reverse"
        }
    }
}
