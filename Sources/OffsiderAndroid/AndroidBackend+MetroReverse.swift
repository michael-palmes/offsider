import Foundation
import OffsiderCore

/// The reverses `session stop` took off one phone.
public struct MetroReverseRemoval: Equatable, Sendable {
    public let serial: String
    public let ports: [Int]
}

extension AndroidBackend: MetroReverseSetting {
    /// Records the port before asking adb, so a reverse is never left without a record, and drops it again when adb refuses.
    public func addMetroReverse(port: Int, on id: DeviceID) async throws {
        let serial = id.rawValue
        guard case .androidName = DeviceIDClassifier.classify(serial) else {
            throw ExpoDevClientError(.noRoute, "Offsider sets an adb reverse only on a USB phone, and \(serial) is not one.")
        }
        if let problem = MetroReverse.refusal(port: port) { throw ExpoDevClientError(.noRoute, problem) }
        try await prepare()
        if case .tcp(_, let server) = try LoopbackEndpoint.adbServer(environment: host.environment), Int(server) == port {
            throw ExpoDevClientError(.noRoute, "Port \(port) is the adb server's own, never Metro.")
        }
        guard let directory = host.metroReverseDirectory() else {
            throw ExpoDevClientError(.noRoute, "Offsider has no private folder to record an adb reverse in, so it set none.")
        }
        let phone = try await requireConnectedPhone(serial)
        guard let transportId = phone.transportId else {
            throw ExpoDevClientError(.noRoute, "adb did not number \(serial)'s connection, so Offsider could not record an adb reverse and set none.")
        }
        let store = MetroReverseStore(directory: directory)
        let earlier = store.load(serial: serial).flatMap { $0.transportId == transportId ? $0 : nil }
            ?? MetroReverseRecord(serial: serial, transportId: transportId, ports: [])
        var record = earlier
        record.ports = Array(Set(record.ports + [port])).sorted()
        try store.save(record)
        do {
            try await requireClient().deviceCommand(MetroReverse.addService(port: port), on: serial)
        } catch {
            try? store.save(earlier)
            throw error
        }
    }

    /// Takes off the reverses Offsider recorded on `serial` (every phone without one) and no other; a phone gone or reconnected only loses its record.
    public static func removeMetroReverses(host: AndroidHost, serial: String? = nil) async -> [MetroReverseRemoval] {
        guard let directory = host.metroReverseDirectory() else { return [] }
        let store = MetroReverseStore(directory: directory)
        let records = serial.map { store.load(serial: $0).map { [$0] } ?? [] } ?? store.all()
        guard !records.isEmpty, let endpoint = try? LoopbackEndpoint.adbServer(environment: host.environment) else { return [] }
        let client = AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing)
        let rows: [AdbDeviceEntry]
        do {
            rows = try await client.devices()
        } catch let error as AndroidError where error.kind == .adbServerNotRunning {
            rows = []
        } catch {
            return []
        }
        var removed: [MetroReverseRemoval] = []
        for record in records {
            var left = record
            guard rows.contains(where: { $0.serial == record.serial && $0.properties["transport_id"] == record.transportId }) else {
                left.ports = []
                try? store.save(left)
                continue
            }
            guard let listing = try? await client.deviceQuery("reverse:list-forward", on: record.serial) else { continue }
            var ports: [Int] = []
            for port in record.ports {
                // A port listed otherwise was rebound by someone else, so it is theirs now.
                if MetroReverse.mapsSamePort(listing, port: port) {
                    guard (try? await client.deviceCommand(MetroReverse.removeService(port: port), on: record.serial)) != nil else { continue }
                    ports.append(port)
                }
                left.ports.removeAll { $0 == port }
            }
            try? store.save(left)
            if !ports.isEmpty { removed.append(MetroReverseRemoval(serial: record.serial, ports: ports)) }
        }
        return removed
    }
}

extension AndroidHost {
    /// The ports Offsider recorded on `serial` for its current connection, for `doctor`.
    func recordedMetroPorts(serial: String, transportId: String?) -> [Int] {
        guard let transportId, let directory = metroReverseDirectory(),
              let record = MetroReverseStore(directory: directory).load(serial: serial), record.transportId == transportId else { return [] }
        return record.ports
    }
}
