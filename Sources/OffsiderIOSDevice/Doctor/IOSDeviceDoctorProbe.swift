import Foundation
import OffsiderCore

/// Gathers `IOSDeviceDoctorFacts` through `devicectl`; every verdict comes from `IOSDeviceDoctorRules`.
@MainActor
public struct IOSDeviceDoctorProbe {
    public static let usbmuxdSocket = "/var/run/usbmuxd"
    static let teamVariable = "OFFSIDER_IOS_TEAM_ID"

    let host: IOSDeviceHost
    let xcodeTeams: @Sendable () -> [String]

    public init(host: IOSDeviceHost = .live(), xcodeTeams: @escaping @Sendable () -> [String] = IOSDeviceDoctorProbe.signedInTeams) {
        self.host = host
        self.xcodeTeams = xcodeTeams
    }

    public struct Result: Sendable {
        public let facts: IOSDeviceDoctorFacts
        public let xcode: XcodeLocation?
    }

    public func run(udid: String) async -> Result {
        let team: IOSDeviceDoctorFacts.TeamFact = host.environment[Self.teamVariable].flatMap { $0.isEmpty ? nil : .environment($0) }
            ?? .xcodeTeams(xcodeTeams())
        var facts = IOSDeviceDoctorFacts(udid: udid, xcode: .notFound("No Xcode was found"), usbmuxdSocket: host.fileExists(Self.usbmuxdSocket), team: team)
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

    /// `--fix` on a phone: mounts the developer disk image, and nothing else.
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
