import Darwin
import Foundation
import Security

/// Whether the process on the other end of a Unix socket is signed code that satisfies a requirement, read through its audit token.
public enum PeerCodeIdentity {
    /// A compiled code requirement; `SecRequirement` is immutable and safe to share across threads.
    public struct Requirement: @unchecked Sendable, CustomStringConvertible {
        public let text: String
        let compiled: SecRequirement

        public var description: String { text }
    }

    /// One connection's answer: who the peer was and whether it may talk to the broker.
    public struct Verdict: Equatable, Sendable {
        public let pid: pid_t
        /// The peer's code directory hash in hex, when it could be read.
        public let cdhash: String?
        public let accepted: Bool
        /// True when the process itself was found, so a refusal means its code does not satisfy the requirement.
        public let identified: Bool
        /// Why the peer was refused; nil when accepted.
        public let detail: String?
    }

    /// The designated requirement of the running process: for a Developer ID build its team and identifier, for an ad-hoc build its own cdhash.
    /// Read it once at start, before a rebuild can replace the executable on disk.
    public static func ownRequirement() throws -> Requirement {
        var own: SecCode?
        var status = unsafe SecCodeCopySelf([], &own)
        guard status == errSecSuccess, let own else { throw CodeSignatureCheck.Failure(step: "SecCodeCopySelf", status: status) }
        var designated: SecRequirement?
        status = unsafe SecCodeCopyDesignatedRequirement(staticCode(own), [], &designated)
        guard status == errSecSuccess, let designated else { throw CodeSignatureCheck.Failure(step: "SecCodeCopyDesignatedRequirement", status: status) }
        var text: CFString?
        status = unsafe SecRequirementCopyString(designated, [], &text)
        guard status == errSecSuccess, let text else { throw CodeSignatureCheck.Failure(step: "SecRequirementCopyString", status: status) }
        return Requirement(text: text as String, compiled: designated)
    }

    public static func requirement(_ text: String) throws -> Requirement {
        var compiled: SecRequirement?
        let status = unsafe SecRequirementCreateWithString(text as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else { throw CodeSignatureCheck.Failure(step: "SecRequirementCreateWithString", status: status) }
        return Requirement(text: text, compiled: compiled)
    }

    /// The connected peer's audit token (`LOCAL_PEERTOKEN`), which names the exact process, unlike a pid that can be reused.
    public static func auditToken(of descriptor: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard unsafe getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }

    public static func peerPID(of descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard unsafe getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The pid an audit token carries (`audit_token_to_pid`).
    public static func pid(of token: audit_token_t) -> pid_t {
        pid_t(bitPattern: token.val.5)
    }

    /// Checks the process the audit token names against `requirement`.
    public static func check(auditToken token: audit_token_t, requirement: Requirement) -> Verdict {
        var token = token
        let data = withUnsafeBytes(of: &token) { unsafe Data($0) }
        return check(pid: pid(of: token), attributes: [kSecGuestAttributeAudit: data as CFData], requirement: requirement)
    }

    /// Checks by pid alone; only for a socket that gives no audit token, since a pid can be reused between the read and the check.
    public static func check(pid: pid_t, requirement: Requirement) -> Verdict {
        check(pid: pid, attributes: [kSecGuestAttributePid: NSNumber(value: pid)], requirement: requirement)
    }

    /// The peer of a connected Unix socket, by audit token, else by pid; refused when neither can be read.
    public static func check(peer descriptor: Int32, requirement: Requirement) -> Verdict {
        if let token = auditToken(of: descriptor) {
            return check(auditToken: token, requirement: requirement)
        }
        guard let pid = peerPID(of: descriptor) else {
            return Verdict(pid: 0, cdhash: nil, accepted: false, identified: false, detail: "the peer process could not be identified")
        }
        return check(pid: pid, requirement: requirement)
    }

    private static func check(pid: pid_t, attributes: [CFString: Any], requirement: Requirement) -> Verdict {
        var guest: SecCode?
        let status = unsafe SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest)
        guard status == errSecSuccess, let guest else {
            return Verdict(pid: pid, cdhash: nil, accepted: false, identified: false, detail: CodeSignatureCheck.Failure(step: "SecCodeCopyGuestWithAttributes", status: status).description)
        }
        let hash = cdhash(of: guest)
        // Never reaches the network: no revocation check.
        let validity = SecCodeCheckValidity(guest, [.noNetworkAccess], requirement.compiled)
        guard validity == errSecSuccess else {
            return Verdict(pid: pid, cdhash: hash, accepted: false, identified: true, detail: CodeSignatureCheck.Failure(step: "SecCodeCheckValidity", status: validity).description)
        }
        return Verdict(pid: pid, cdhash: hash, accepted: true, identified: true, detail: nil)
    }

    /// A running `SecCode` is also a `SecStaticCode` to every call that reads a signature.
    private static func staticCode(_ code: SecCode) -> SecStaticCode {
        unsafe unsafeBitCast(code, to: SecStaticCode.self)
    }

    private static func cdhash(of code: SecCode) -> String? {
        var info: CFDictionary?
        guard unsafe SecCodeCopySigningInformation(staticCode(code), [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { unsafe String(format: "%02x", $0) }.joined()
    }
}
