import Foundation
import OffsiderCore

/// The reverses `session stop` took off one phone, or could not.
public struct MetroReverseRemoval: Equatable, Sendable {
    public let serial: String
    public let ports: [Int]

    public init(serial: String, ports: [Int]) {
        self.serial = serial
        self.ports = ports
    }
}

/// What a removal did: `failed` may still be set, and stays recorded for the next try.
public struct MetroReverseOutcome: Equatable, Sendable {
    public var removed: [MetroReverseRemoval] = []
    public var failed: [MetroReverseRemoval] = []

    public init(removed: [MetroReverseRemoval] = [], failed: [MetroReverseRemoval] = []) {
        self.removed = removed
        self.failed = failed
    }
}

/// What Offsider recorded on one phone, read from this Mac with nothing sent to it, so it may be stale.
public struct RecordedPhoneState: Equatable, Sendable {
    public let serial: String
    public let reverses: [Int]
    public let posture: Bool
    public let airplane: Bool

    public init(serial: String, reverses: [Int], posture: Bool, airplane: Bool = false) {
        self.serial = serial
        self.reverses = reverses
        self.posture = posture
        self.airplane = airplane
    }
}

extension AndroidBackend: MetroReverseSetting {
    /// Records the port before asking adb, so a reverse is never left without a record, and drops it again only when adb refuses: after a timeout or a dropped link it may be set.
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
        guard let directory = host.metroReverseDirectory(true) else {
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
        } catch let error as AndroidError where error.refusedByAdb {
            try? store.save(earlier)
            throw error
        }
    }

    public func recordedMetroPorts(on id: DeviceID) async -> [Int] {
        guard (try? await prepare()) != nil, let phone = try? await requireConnectedPhone(id.rawValue) else { return [] }
        return host.recordedMetroPorts(serial: id.rawValue, transportId: phone.transportId)
    }

    /// Takes off the reverses Offsider recorded on `serial` (every phone without one) and no other, except ports in `keeping`; a phone gone or reconnected only loses its record.
    public static func removeMetroReverses(host: AndroidHost, serial: String? = nil, keeping: [Int] = []) async -> MetroReverseOutcome {
        guard let directory = host.metroReverseDirectory(false) else { return MetroReverseOutcome() }
        let store = MetroReverseStore(directory: directory)
        let ports = { (record: MetroReverseRecord) in record.ports.filter { !keeping.contains($0) } }
        let records = (serial.map { store.load(serial: $0).map { [$0] } ?? [] } ?? store.all()).filter { !ports($0).isEmpty }
        guard !records.isEmpty else { return MetroReverseOutcome() }
        var outcome = MetroReverseOutcome()
        func fail(_ record: MetroReverseRecord, _ failed: [Int]) {
            if !failed.isEmpty { outcome.failed.append(MetroReverseRemoval(serial: record.serial, ports: failed)) }
        }
        guard let endpoint = try? LoopbackEndpoint.adbServer(environment: host.environment) else {
            records.forEach { fail($0, ports($0)) }
            return outcome
        }
        let client = AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing)
        let rows: [AdbDeviceEntry]
        do {
            rows = try await client.devices()
        } catch let error as AndroidError where error.kind == .adbServerNotRunning {
            rows = []
        } catch {
            records.forEach { fail($0, ports($0)) }
            return outcome
        }
        for record in records {
            guard rows.contains(where: { $0.serial == record.serial && $0.properties["transport_id"] == record.transportId }) else {
                Self.forget(record.ports, of: record, in: store)
                continue
            }
            guard let listing = try? await client.deviceQuery("reverse:list-forward", on: record.serial) else {
                fail(record, ports(record))
                continue
            }
            var removed: [Int] = []
            var failed: [Int] = []
            var handled: [Int] = []
            for port in ports(record) {
                // A port listed otherwise was rebound by someone else, so it is theirs now.
                if MetroReverse.mapsSamePort(listing, port: port) {
                    guard (try? await client.deviceCommand(MetroReverse.removeService(port: port), on: record.serial)) != nil else {
                        failed.append(port)
                        continue
                    }
                    removed.append(port)
                }
                handled.append(port)
            }
            Self.forget(handled, of: record, in: store)
            if !removed.isEmpty { outcome.removed.append(MetroReverseRemoval(serial: record.serial, ports: removed)) }
            fail(record, failed)
        }
        return outcome
    }

    /// The reverses, overrides and airplane modes Offsider recorded, on `serial` or on every device, without reaching adb.
    public static func recordedPhoneState(host: AndroidHost, serial: String? = nil) -> [RecordedPhoneState] {
        let reverses = host.metroReverseDirectory(false).map { directory -> [MetroReverseRecord] in
            let store = MetroReverseStore(directory: directory)
            return serial.map { store.load(serial: $0).map { [$0] } ?? [] } ?? store.all()
        } ?? []
        let postures = host.postureRecordDirectory(false).map { directory -> [String] in
            let store = AndroidPostureRecordStore(directory: directory)
            return (serial.map { store.load(serial: $0).map { [$0] } ?? [] } ?? store.all()).map(\.serial)
        } ?? []
        let airplanes = host.airplaneRecordDirectory(false).map { directory in
            AndroidAirplaneRecordStore(directory: directory).all().filter { serial == nil || isRecord($0, of: serial!, host: host) }.map { currentSerial(of: $0, host: host) ?? $0.name }
        } ?? []
        return Set(reverses.map(\.serial) + postures + airplanes).sorted().map { phone in
            RecordedPhoneState(serial: phone, reverses: reverses.first { $0.serial == phone }?.ports ?? [], posture: postures.contains(phone), airplane: airplanes.contains(phone))
        }
    }

    /// Drops `ports` from the record as it now stands, so a port `rn open` recorded meanwhile stays.
    private static func forget(_ ports: [Int], of record: MetroReverseRecord, in store: MetroReverseStore) {
        guard var current = store.load(serial: record.serial), current.transportId == record.transportId else { return }
        current.ports.removeAll { ports.contains($0) }
        try? store.save(current)
    }
}

extension AndroidHost {
    /// The ports Offsider recorded on `serial` for its current connection, for `doctor`.
    func recordedMetroPorts(serial: String, transportId: String?) -> [Int] {
        guard let transportId, let directory = metroReverseDirectory(false),
              let record = MetroReverseStore(directory: directory).load(serial: serial), record.transportId == transportId else { return [] }
        return record.ports
    }
}
