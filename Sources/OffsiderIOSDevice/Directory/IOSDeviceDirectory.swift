import Foundation
import OffsiderCore

/// The physical iPhones and iPads CoreDevice knows, listed once per command.
@MainActor
public final class IOSDeviceDirectory {
    static let listArguments = ["list", "devices", "--json-output", "-", "--timeout", "9", "-q"]
    static let listTimeout: TimeInterval = 12
    static let infoTimeout: TimeInterval = 25

    let host: IOSDeviceHost
    private var cached: DevicectlDeviceList?

    public init(host: IOSDeviceHost) {
        self.host = host
    }

    public func list() async throws -> DevicectlDeviceList {
        if let cached { return cached }
        let output = try await run(Self.listArguments, label: "list devices", udid: nil, timeout: Self.listTimeout)
        let list: DevicectlDeviceList
        do {
            list = try DevicectlDeviceList.parse(Data(output.utf8))
        } catch let error as DevicectlDeviceList.ParseError {
            throw IOSDeviceError.devicectlFailed("list devices", udid: nil, detail: error.detail)
        }
        cached = list
        return list
    }

    public func device(udid: String) async throws -> DevicectlDevice? {
        try await list().devices.first { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
    }

    public func deviceSupportFinalized(_ device: DevicectlDevice) -> Bool {
        IOSDeviceReadiness.deviceSupportMarkers(for: device, home: host.homeDirectory).contains(where: host.fileExists)
    }

    public func readiness(of device: DevicectlDevice) -> IOSDeviceReadiness {
        IOSDeviceReadiness.assess(device, deviceSupportFinalized: deviceSupportFinalized(device))
    }

    public func summaries() async throws -> [DeviceSummary] {
        try await list().devices.map { device in
            DeviceSummary(
                id: device.udid,
                platform: .ios,
                state: readiness(of: device).stateText,
                name: device.label,
                osVersion: device.osVersion.map { "iOS \($0)" },
                deviceType: device.marketingName ?? device.productType,
                kind: .physical,
                connection: Self.connection(device.transportType)
            )
        }
    }

    /// Any `device info` call brings the CoreDevice tunnel up; `ddiServices` also mounts a missing disk image.
    public func wake(udid: String) async throws {
        _ = try await run(
            ["device", "info", "ddiServices", "--device", udid, "--timeout", "20", "--json-output", "-", "-q"],
            label: "device info ddiServices",
            udid: udid,
            timeout: Self.infoTimeout
        )
        cached = nil
    }

    func run(_ arguments: [String], label: String, udid: String?, timeout: TimeInterval) async throws -> String {
        let result: ProcessCaptureResult
        do {
            result = try await host.devicectl.run(arguments, timeout: timeout)
        } catch let error as IOSDeviceError {
            throw error
        } catch {
            throw IOSDeviceError.devicectlFailed(label, udid: udid, detail: error.localizedDescription)
        }
        guard result.status == 0 else {
            let detail = result.stderr.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "exit \(result.status)"
            throw IOSDeviceError.devicectlFailed(label, udid: udid, detail: detail)
        }
        return result.stdout
    }

    static func connection(_ transportType: String?) -> String? {
        switch transportType {
        case "wired": return "usb"
        case "localNetwork": return "network"
        default: return nil
        }
    }
}
