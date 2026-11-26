import Foundation

/// `dumpsys fingerprint` as phones and emulators print it, in AOSP's shapes with invented values.
enum FingerprintDumpFixtures {
    /// Android 12 and later: a header per sensor, its JSON line (`org.json` escapes `/`), then the scheduler dump.
    nonisolated static func sensor(_ id: Int, provider: String = "FingerprintProvider", service: String = #"FingerprintProvider\/default"#, prints: String) -> String {
        """
        Dumping for sensorId: \(id), provider: \(provider)
        Fps state: 0
        {"service":"\(service)","prints":[\(prints)]}
        HAL deaths since last reboot: 0
        ---AuthSessionCoordinator logs begin---
        AuthSessionCoordinator{mIsAuthenticating=false, mAllowedStrength=15}
        ---AuthSessionCoordinator logs end  ---
        Dump of BiometricScheduler \(provider)/\(id)
        Type: 2
        Current operation: null
        Pending operations: 0

        """
    }

    nonisolated static func user(_ id: Int, count: Int) -> String {
        #"{"id":\#(id),"count":\#(count),"accept":17,"reject":3,"acquire":26,"lockout":0,"permanentLockout":0,"acceptCrypto":2,"rejectCrypto":0,"acquireCrypto":2}"#
    }

    /// One under-display sensor, one user with two prints.
    nonisolated static let oneSensorEnrolled = sensor(0, prints: user(0, count: 2))
    nonisolated static let oneSensorEmpty = sensor(0, prints: user(0, count: 0))

    /// A real sensor with nothing enrolled beside a second one that holds a print.
    nonisolated static let twoSensors = sensor(0, prints: user(0, count: 0)) + sensor(1, service: #"FingerprintProvider\/virtual"#, prints: user(0, count: 1))

    /// The owner with a print and a second user with none, as on a phone shared by two people.
    nonisolated static let twoUsers = sensor(0, prints: user(0, count: 1) + "," + user(10, count: 0))

    /// Vendor lines around the dump, and profile users (a clone and a private space) that hold no prints of their own.
    nonisolated static let profileUsers = """
    FingerprintService state: enabled
    Sensor vendor: example
    \(sensor(0, service: #"FingerprintProvider\/vendor"#, prints: user(0, count: 3) + "," + user(95, count: 0) + "," + user(150, count: 0)))
    Vendor log ends
    """

    /// Android 9 to 11, before sensors had their own header.
    nonisolated static let legacy = """
    {"service":"Fingerprint Manager","prints":[{"id":0,"count":1,"accept":4,"reject":0,"acceptCrypto":0,"rejectCrypto":0,"permanentLockout":0,"lockout":0}]}
    HAL deaths since last reboot: 0

    """

    /// `androidStatusScript`'s output: the current user, the marker, then the dump.
    nonisolated static func status(user: String, _ dump: String) -> String {
        "\(user)\n__offsider_fingerprint__\n\(dump)"
    }
}
