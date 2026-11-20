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
        /// `devicectl` itself said so, unlike a dark screen with a passcode.
        case locked
        case unreadable(String)
    }

    public enum TeamFact: Equatable, Sendable {
        case environment(String)
        /// Recorded by `devices add --team`.
        case allowance(String)
        /// Neither was set; Xcode's signed-in teams are counted, never used.
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

    /// What this process's desktop session offers the screen stream.
    public enum Desktop: Equatable, Sendable {
        case awake
        case asleep
        case none
    }

    /// The device's session broker, read without starting it or its stream.
    public enum SessionFact: Equatable, Sendable {
        case notRunning(Desktop)
        /// `stream` is the broker's stream state (`opening`, `live`, `failed`, `closed`).
        case running(stream: String, detail: String?)
        /// Its process is alive but its socket did not answer.
        case unanswered
    }

    /// The runner's cached build for this device's team and prefix, read from this Mac without building anything.
    public enum RunnerBuildFact: Equatable, Sendable {
        /// The team or prefix cannot be used as set; `message` says why and what to do.
        case unsettled(message: String, hint: String?)
        case built(team: String, prefix: String)
        /// Built, but an installed app's provisioning profile has expired or ends within an hour, so the next start rebuilds it.
        case profileExpiring(team: String, prefix: String, expires: Date, expired: Bool)
        /// `needsPerson` when the prefix is new to this Mac, so its first build waits on Touch ID.
        case notBuilt(team: String, prefix: String, needsPerson: Bool)
        /// The last build failed because another Apple team owns one of the runner's App IDs; `fix` gives the device a prefix of its own.
        case appIDTaken(appID: String, team: String, fix: String)
        /// The last build failed because the team has not registered the device, or no profile covers it.
        case notRegistered(team: String)
        /// The last build failed for another reason; its log is at `log`.
        case failed(team: String, prefix: String, log: String)
    }

    /// Whether the device trusts the certificate that signs the runner, as the last runner start on it showed.
    public enum RunnerTrustFact: Equatable, Sendable {
        /// The last start failed because the device does not trust this team's developer certificate.
        case untrusted(team: String)
        /// A runner is running on it now.
        case running
        /// No start has failed on it and none is running, so it is not known yet.
        case unknown
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
    /// Nil when no team is settled for the runner or its source is missing.
    public var runnerBuild: RunnerBuildFact?
    /// Nil when no team is settled for the runner.
    public var runnerTrust: RunnerTrustFact?

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
