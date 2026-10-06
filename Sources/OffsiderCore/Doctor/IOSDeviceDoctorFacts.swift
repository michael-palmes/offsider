import Foundation

/// What `offsider doctor --device <iPhone UDID>` observed; the rules turn it into checks.
public struct IOSDeviceDoctorFacts: Equatable, Sendable {
    public enum XcodeFact: Equatable, Sendable {
        case found(developerDir: String, version: String?, build: String?)
        case notFound(String)
    }

    public enum ListingFact: Equatable, Sendable {
        case listed(IOSDeviceDoctorRow)
        case notListed
        case failed(String)
    }

    public enum LockFact: Equatable, Sendable {
        case read(passcodeRequired: Bool?, backlightOn: Bool?)
        case unreadable(String)
    }

    public enum TeamFact: Equatable, Sendable {
        case environment(String)
        case xcodeTeams([String])
    }

    /// What opening the digitizer socket and probing it showed.
    public enum HIDFact: Equatable, Sendable {
        /// Below CoreDevice 636 nothing is asked of the device.
        case unsupported(coreDevice: String?)
        case locked
        case socketFailed(String)
        /// The socket opened but its barrier never answered.
        case unresponsive(String)
        /// The barrier or an ordinary probe event was refused while unlocked.
        case refused
        case ready
    }

    /// What usbmuxd's device list said about this UDID.
    public enum UsbmuxFact: Equatable, Sendable {
        case onUSB
        /// Listed over the network only, or not at all.
        case notOnUSB
        case failed(String)
    }

    /// The device's session broker, read without starting it or its stream.
    public enum SessionFact: Equatable, Sendable {
        case notRunning(guiSession: Bool)
        /// `stream` is the broker's stream state (`opening`, `live`, `failed`, `closed`).
        case running(stream: String, detail: String?)
        /// Its process is alive but its socket did not answer.
        case unanswered
    }

    public var udid: String
    public var xcode: XcodeFact
    /// From the `devicectl` reply's `info.version`; nil when `devicectl` did not answer.
    public var coreDeviceVersion: String?
    /// Nil when Xcode was not found, so `devicectl` never ran.
    public var listing: ListingFact?
    /// Nil when the device was not reachable enough to ask.
    public var lock: LockFact?
    /// Nil when the device was not ready for developer services, so no socket was opened.
    public var hid: HIDFact?
    public var usbmuxdSocket: Bool
    /// Nil when usbmuxd was not asked, as when its socket is missing.
    public var usbmux: UsbmuxFact?
    public var team: TeamFact
    /// Nil when it was not checked.
    public var session: SessionFact?

    public init(
        udid: String,
        xcode: XcodeFact,
        coreDeviceVersion: String? = nil,
        listing: ListingFact? = nil,
        lock: LockFact? = nil,
        hid: HIDFact? = nil,
        usbmuxdSocket: Bool,
        usbmux: UsbmuxFact? = nil,
        team: TeamFact
    ) {
        self.udid = udid
        self.xcode = xcode
        self.coreDeviceVersion = coreDeviceVersion
        self.listing = listing
        self.lock = lock
        self.hid = hid
        self.usbmuxdSocket = usbmuxdSocket
        self.usbmux = usbmux
        self.team = team
    }

    public var row: IOSDeviceDoctorRow? {
        if case .listed(let row)? = listing { return row }
        return nil
    }
}

/// The listed device's state, after doctor's own `devicectl device info` call woke its tunnel.
public struct IOSDeviceDoctorRow: Equatable, Sendable {
    public var label: String
    public var osVersion: String?
    public var transportType: String?
    public var connectionState: String?
    public var pairingState: String?
    public var developerModeStatus: String?
    public var ddiServicesAvailable: Bool?
    public var deviceSupportFinalized: Bool
    public var tunnelState: String?

    public init(
        label: String,
        osVersion: String?,
        transportType: String?,
        connectionState: String?,
        pairingState: String?,
        developerModeStatus: String?,
        ddiServicesAvailable: Bool?,
        deviceSupportFinalized: Bool,
        tunnelState: String?
    ) {
        self.label = label
        self.osVersion = osVersion
        self.transportType = transportType
        self.connectionState = connectionState
        self.pairingState = pairingState
        self.developerModeStatus = developerModeStatus
        self.ddiServicesAvailable = ddiServicesAvailable
        self.deviceSupportFinalized = deviceSupportFinalized
        self.tunnelState = tunnelState
    }

    public var isConnected: Bool {
        connectionState != "unavailable" && transportType != nil
    }

    public var isWired: Bool { transportType == "wired" }
}
