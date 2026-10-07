import Foundation
import OffsiderCore

/// Gathers `IOSDeviceDoctorFacts` through `devicectl`; every verdict comes from `IOSDeviceDoctorRules`.
@MainActor
public struct IOSDeviceDoctorProbe {
    public static let usbmuxdSocket = "/var/run/usbmuxd"
    static let teamVariable = "OFFSIDER_IOS_TEAM_ID"

    /// Opens the digitizer socket to a device by CoreDevice identifier, display name and UDID.
    public typealias HIDProbe = @MainActor (_ identifier: String, _ name: String, _ udid: String) async -> IOSDeviceDoctorFacts.HIDFact

    let host: IOSDeviceHost
    let xcodeTeams: @Sendable () -> [String]
    let hid: HIDProbe
    let session: SessionProbe

    /// Reads a device's session broker by UDID, never starting it.
    public typealias SessionProbe = @MainActor (_ udid: String) async -> IOSDeviceDoctorFacts.SessionFact

    public init(
        host: IOSDeviceHost = .live(),
        xcodeTeams: @escaping @Sendable () -> [String] = IOSDeviceDoctorProbe.signedInTeams,
        hid: @escaping HIDProbe = IOSDeviceDoctorProbe.liveHID,
        session: SessionProbe? = nil
    ) {
        self.host = host
        self.xcodeTeams = xcodeTeams
        self.hid = hid
        self.session = session ?? { udid in await Self.sessionFact(udid, root: host.privateRoot) }
    }

    /// The broker's record and `ping`; a broker that is not running is reported, not started.
    public static func sessionFact(_ udid: String, root: String) async -> IOSDeviceDoctorFacts.SessionFact {
        let store = DeviceSessionStore(root: root)
        guard let record = try? store.read(udid: udid) else { return .notRunning(guiSession: IOSDeviceScreenStream.hasDisplay()) }
        let manager = DeviceSessionManager(
            store: store, processes: OffsiderSelfProcesses(executable: URL(fileURLWithPath: "/usr/bin/false")), environment: [:], log: { _, _ in }
        )
        let status = await manager.status(of: record)
        guard status.alive else { return .notRunning(guiSession: IOSDeviceScreenStream.hasDisplay()) }
        guard let stream = status.reply?.stream else { return .unanswered }
        let detail: String?
        switch stream.state {
        case .live: detail = "live, \(stream.width ?? 0) x \(stream.height ?? 0)"
        case .failed: detail = stream.detail
        case .opening, .closed: detail = nil
        }
        return .running(stream: stream.state.rawValue, detail: detail)
    }

    public struct Result: Sendable {
        public let facts: IOSDeviceDoctorFacts
        public let xcode: XcodeLocation?
    }

    public func run(udid: String) async -> Result {
        let team: IOSDeviceDoctorFacts.TeamFact = host.environment[Self.teamVariable].flatMap { $0.isEmpty ? nil : .environment($0) }
            ?? .xcodeTeams(xcodeTeams())
        var facts = IOSDeviceDoctorFacts(udid: udid, xcode: .notFound("No Xcode was found"), usbmuxdSocket: host.fileExists(Self.usbmuxdSocket), team: team)
        if facts.usbmuxdSocket { facts.usbmux = await Self.usbmuxFact(udid, usbmux: host.usbmux) }
        let xcode: XcodeLocation
        do {
            xcode = try await host.devicectl.locateXcode()
        } catch {
            facts.xcode = .notFound(Self.message(error))
            return Result(facts: facts, xcode: nil)
        }
        facts.xcode = .found(developerDir: xcode.developerDirectory, version: xcode.version, build: xcode.build)

        let directory = IOSDeviceDirectory(host: host)
        let listed: DevicectlDevice?
        do {
            let list = try await directory.list()
            facts.coreDeviceVersion = list.coreDeviceVersion
            listed = list.devices.first { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
        } catch {
            facts.listing = .failed(Self.message(error))
            return Result(facts: facts, xcode: xcode)
        }
        guard var device = listed else {
            facts.listing = .notListed
            return Result(facts: facts, xcode: xcode)
        }
        if device.transportType != nil, device.connectionState != "unavailable", device.pairingState == "paired" {
            // Any `device info` call brings the tunnel up, so the details row shows the state a command would meet.
            if let output = try? await directory.run(Self.info("details", udid: device.udid), label: "device info details", udid: device.udid, timeout: IOSDeviceDirectory.infoTimeout),
               let details = try? DevicectlDeviceList.parseDetails(Data(output.utf8)) {
                device = details
            }
            facts.lock = await lockFact(device.udid, directory: directory)
            if device.transportType == "wired", device.developerModeStatus == "enabled", device.ddiServicesAvailable == true {
                facts.hid = await hidFact(device, coreDeviceVersion: facts.coreDeviceVersion)
                facts.session = await session(device.udid)
            }
        }
        facts.listing = .listed(IOSDeviceDoctorRow(
            label: device.label,
            osVersion: device.osVersion,
            transportType: device.transportType,
            connectionState: device.connectionState,
            pairingState: device.pairingState,
            developerModeStatus: device.developerModeStatus,
            ddiServicesAvailable: device.ddiServicesAvailable,
            deviceSupportFinalized: directory.deviceSupportFinalized(device),
            tunnelState: device.tunnelState
        ))
        return Result(facts: facts, xcode: xcode)
    }

    /// The device's row in usbmuxd's list, read off the main actor.
    static func usbmuxFact(_ udid: String, usbmux: any UsbmuxListing) async -> IOSDeviceDoctorFacts.UsbmuxFact {
        do {
            return try await Task.detached { try usbmux.listsOnUSB(udid) }.value ? .onUSB : .notOnUSB
        } catch UsbmuxError.socketUnavailable(let detail) {
            return .failed(detail)
        } catch UsbmuxError.timedOut {
            return .failed("it did not answer in time")
        } catch {
            return .failed("its reply could not be read")
        }
    }

    /// `--fix` on a wired phone: mounts the developer disk image, and nothing else.
    public func mountDDI(udid: String, facts: IOSDeviceDoctorFacts) async -> DoctorFixResult {
        let action = "Mount the developer disk image with devicectl device info ddiServices --auto-mount-ddis"
        guard IOSDeviceDoctorRules.isDDIFixable(facts) else {
            return DoctorFixResult(id: .iosDeviceDDI, action: action, outcome: .skipped, detail: "Nothing to mount")
        }
        do {
            _ = try await IOSDeviceDirectory(host: host).run(
                ["device", "info", "ddiServices", "--device", udid, "--auto-mount-ddis", "--timeout", "60", "--json-output", "-", "-q"],
                label: "device info ddiServices",
                udid: udid,
                timeout: 70
            )
            return DoctorFixResult(id: .iosDeviceDDI, action: action, outcome: .applied, detail: "Mounted the developer disk image")
        } catch {
            return DoctorFixResult(id: .iosDeviceDDI, action: action, outcome: .failed, detail: Self.message(error))
        }
    }

    private func lockFact(_ udid: String, directory: IOSDeviceDirectory) async -> IOSDeviceDoctorFacts.LockFact {
        do {
            let lock = try await directory.run(Self.info("lockState", udid: udid), label: "device info lockState", udid: udid, timeout: IOSDeviceDirectory.infoTimeout)
            let displays = try await directory.run(Self.info("displays", udid: udid), label: "device info displays", udid: udid, timeout: IOSDeviceDirectory.infoTimeout)
            return .read(passcodeRequired: DevicectlLockInfo.passcodeRequired(Data(lock.utf8)), backlightOn: DevicectlLockInfo.backlightOn(Data(displays.utf8)))
        } catch {
            return .unreadable(Self.message(error))
        }
    }

    /// Below the HID floor nothing is asked of the device.
    private func hidFact(_ device: DevicectlDevice, coreDeviceVersion: String?) async -> IOSDeviceDoctorFacts.HIDFact {
        if let version = coreDeviceVersion.flatMap(CoreDeviceVersion.init), !version.supportsHID {
            return .unsupported(coreDevice: coreDeviceVersion)
        }
        guard let identifier = device.coreDeviceIdentifier else {
            return .socketFailed("devicectl did not report the CoreDevice identifier")
        }
        return await hid(identifier, DeviceName.display(device.udid, label: device.label), device.udid)
    }

    /// The button socket and its barrier; a device answers the barrier only when CoreDevice HID is reachable, and nothing is pressed.
    public static let liveHID: HIDProbe = { identifier, name, udid in
        let installed = CoreDeviceVersion.installed()
        guard let version = installed, version.supportsHID else {
            return .unsupported(coreDevice: installed?.description)
        }
        let link: DeviceDTUHID
        do {
            link = try await DeviceDTUHID.connect(
                deviceIdentifier: identifier, feature: DTUHIDMessage.buttonService, version: version, name: name, udid: udid, anySent: false
            )
        } catch let error as IOSDeviceError {
            switch error.kind {
            case .locked: return .locked
            case .uiAutomationOff: return .refused
            case .xcodeTooOld: return .unsupported(coreDevice: version.description)
            default: return .socketFailed(error.message)
            }
        } catch {
            return .socketFailed(error.localizedDescription)
        }
        await link.close()
        return .ready
    }

    static func info(_ topic: String, udid: String) -> [String] {
        ["device", "info", topic, "--device", udid, "--timeout", "20", "--json-output", "-", "-q"]
    }

    static func message(_ error: Error) -> String {
        (error as? IOSDeviceError)?.message ?? error.localizedDescription
    }

    /// Distinct team ids from Xcode's signed-in accounts; account names never leave this function.
    public static let signedInTeams: @Sendable () -> [String] = {
        guard let accounts = UserDefaults(suiteName: "com.apple.dt.Xcode")?.dictionary(forKey: "IDEProvisioningTeams") else { return [] }
        let teams = accounts.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }.compactMap { $0["teamID"] as? String }
        return Array(Set(teams)).sorted()
    }
}
