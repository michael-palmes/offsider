import Foundation
import OffsiderAndroid
import OffsiderCore

/// Names a device for the sign-in ledger from local files and the process table alone, so `login` can record after its tap without touching the device.
enum SignInDevice {
    /// The platform and stable key; an emulator serial maps to its AVD through its discovery file. Nil for an unknown serial or an invalid id.
    static func key(rawID: String, host: AndroidHost = .live()) -> (platform: DevicePlatform, key: String)? {
        if let known = StableDeviceKey.of(id: rawID) { return known }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .androidSerial = DeviceIDClassifier.classify(id),
              let avd = AndroidBackend.emulatorAVD(serial: id, host: host), !avd.isEmpty else {
            return nil
        }
        return (.android, avd)
    }

    /// The running device's boot marker; nil for a phone, a physical iPhone or a device that is not running.
    static func bootMarker(platform: DevicePlatform, key: String, host: AndroidHost = .live()) -> String? {
        switch platform {
        case .ios:
            guard case .iosSimulator(let udid) = DeviceIDClassifier.classify(key) else { return nil }
            return IOSBackend.bootMarker(simulatorUDID: udid)
        case .android:
            return AndroidBackend.emulatorBootMarker(avd: key, host: host)
        }
    }
}

/// The sign-in ledger as `login` and `credential` use it, by device id and canonical app; tests give a temporary root and a fake Android host.
struct SignInTracker {
    var ledger: SignInLedger
    var host: AndroidHost
    var now: () -> Date

    static func live() -> SignInTracker {
        SignInTracker(ledger: SignInLedger(), host: .live(), now: { Date() })
    }

    func key(of deviceID: String) -> (platform: DevicePlatform, key: String)? {
        SignInDevice.key(rawID: deviceID, host: host)
    }

    func bootMarker(platform: DevicePlatform, key: String) -> String? {
        SignInDevice.bootMarker(platform: platform, key: key, host: host)
    }

    /// Records who Offsider just signed in; nil when the device has no stable key or the write failed.
    @discardableResult
    func record(app: String, foreground: String, key: String, deviceID: String) -> SignInRecord? {
        guard let device = self.key(of: deviceID) else { return nil }
        let record = SignInRecord(
            app: app, foreground: foreground, key: key, platform: device.platform, device: device.key,
            since: now(), bootMarker: bootMarker(platform: device.platform, key: device.key)
        )
        guard (try? ledger.record(record)) != nil else { return nil }
        return record
    }

    /// The last sign-in to the app on this device, and whether the device restarted since.
    func last(app: String, deviceID: String) -> (record: SignInRecord, restarted: Bool?)? {
        guard let device = key(of: deviceID), let record = ledger.record(platform: device.platform, device: device.key, app: app) else { return nil }
        return (record, SignInLedger.restarted(recorded: record.bootMarker, current: bootMarker(platform: device.platform, key: device.key)))
    }

    /// Reads each device's boot marker once; on iOS each read scans the process table.
    func signIns(app: String) -> [String: [LoginSignIn]] {
        var markers: [String: String?] = [:]
        return ledger.signIns(app: app) { platform, key in
            let id = "\(platform.rawValue):\(key)"
            if let known = markers[id] { return known }
            let marker = bootMarker(platform: platform, key: key)
            markers[id] = .some(marker)
            return marker
        }
    }

    /// The raw key last signed in on the device; reads no boot marker.
    func signedInHere(app: String, deviceID: String) -> String? {
        guard let device = key(of: deviceID) else { return nil }
        return ledger.record(platform: device.platform, device: device.key, app: app)?.key
    }

    /// Clears the device's record for the app; a device with no stable key is named by its id, and had nothing recorded.
    func signOut(app: String, deviceID: String) throws -> (platform: DevicePlatform, device: String, cleared: SignInRecord?) {
        let id = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let device = key(of: id) {
            return (device.platform, device.key, ledger.clear(platform: device.platform, device: device.key, app: app))
        }
        guard let platform = DeviceIDClassifier.classify(id).platform else {
            throw CLIError(errorDescription: "\(id) is not a device ID. Run `offsider list-devices` to find device IDs.", reason: .invalidDeviceID, hint: "offsider list-devices")
        }
        return (platform, id, nil)
    }
}
