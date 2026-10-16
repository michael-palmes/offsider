import Foundation
import ObjectiveC
import OffsiderCore
import OffsiderIOSDevice

/// `xcode.private-api`: every recorded private type encoding against the frameworks the simulator path already loaded, and CoreDevice's major.
enum PrivateAPIDoctorRule {
    struct Expectation: Equatable, Sendable {
        /// A class name, or a protocol name when `isProtocol`.
        let owner: String
        let isProtocol: Bool
        let selector: String
        let encoding: String
        let framework: String
    }

    /// Every simulator-side call Offsider casts; AVConference's are checked when an iPhone screen stream starts, since loading it here would cost.
    static var expectations: [Expectation] {
        SimulatorOrientationReader.Encodings.recorded.map {
            Expectation(owner: $0.owner, isProtocol: $0.isProtocol, selector: $0.selector, encoding: $0.encoding, framework: "SimulatorKit")
        } + [
            Expectation(owner: "SimDevice", isProtocol: false, selector: "lookup:error:", encoding: SimulatorDTUHID.lookupEncoding, framework: "CoreSimulator"),
        ]
    }

    /// The installed encoding (offsets stripped) or nil when the class, protocol or method is gone.
    static func installed(_ expectation: Expectation) -> String? {
        let selector = NSSelectorFromString(expectation.selector)
        if expectation.isProtocol {
            return PrivateAPIGuard.encoding(inProtocol: expectation.owner, selector)
        }
        guard let type = NSClassFromString(expectation.owner) else { return nil }
        return PrivateAPIGuard.encoding(of: type, selector)
    }

    /// Reads the runtime only: CoreSimulator and SimulatorKit are loaded by `xcode.frameworks` first, and CoreDevice's version is a plist read.
    static func check() -> DoctorRules.Verdict {
        let changed = expectations.filter { installed($0) != PrivateAPIGuard.strippedEncoding($0.encoding) }
        return verdict(checked: expectations.count, changed: changed, coreDevice: CoreDeviceVersion.installed())
    }

    static func verdict(checked: Int, changed: [Expectation], coreDevice: CoreDeviceVersion?) -> DoctorRules.Verdict {
        if let first = changed.first {
            let more = changed.count > 1 ? " (and \(changed.count - 1) more)" : ""
            return (.fail, "This Xcode's \(first.framework) changed \(first.selector)\(more), so Offsider will refuse that call", "Update Offsider, or select the Xcode it was built for.")
        }
        let summary = "\(checked) recorded types match this Xcode"
        if let coreDevice, let major = coreDevice.components.first, major > CoreDeviceVersion.lastTestedMajor {
            return (.warn, "\(summary); CoreDevice \(coreDevice) is newer than the last tested (\(CoreDeviceVersion.lastTestedMajor))", "If iPhone input or screenshots fail, update Offsider.")
        }
        return (.pass, summary, nil)
    }
}
