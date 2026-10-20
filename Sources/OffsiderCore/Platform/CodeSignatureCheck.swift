import Foundation
import Security

/// Static code-signature checks through the Security framework, for Xcode and the runner products Offsider builds.
public enum CodeSignatureCheck {
    /// Why a signature check failed: the step and its `OSStatus`.
    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public let step: String
        public let status: OSStatus

        public var description: String {
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "\(step): \(message)"
        }
    }

    /// Throws unless the code at `path` is validly signed and satisfies `requirement`; `resources: false` skips sealed resources, which is what keeps a check on Xcode to tens of milliseconds.
    public static func validate(path: String, requirement: String, resources: Bool) throws {
        _ = try checkedCode(path: path, requirement: requirement, resources: resources)
    }

    /// `validate`, then the team the same signature names, if any.
    public static func validatedTeam(path: String, requirement: String, resources: Bool) throws -> String? {
        let code = try checkedCode(path: path, requirement: requirement, resources: resources)
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return (information as NSDictionary?)?[kSecCodeInfoTeamIdentifier] as? String
    }

    private static func checkedCode(path: String, requirement: String, resources: Bool) throws -> SecStaticCode {
        var code: SecStaticCode?
        var status = unsafe SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Failure(step: "SecStaticCodeCreateWithPath", status: status) }
        var compiled: SecRequirement?
        status = unsafe SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else { throw Failure(step: "SecRequirementCreateWithString", status: status) }
        let flags: SecCSFlags = resources ? [] : SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        status = SecStaticCodeCheckValidity(code, flags, compiled)
        guard status == errSecSuccess else { throw Failure(step: "SecStaticCodeCheckValidity", status: status) }
        return code
    }

    /// `validate` as a yes or no.
    public static func satisfies(path: String, requirement: String, resources: Bool) -> Bool {
        do {
            try validate(path: path, requirement: requirement, resources: resources)
            return true
        } catch {
            return false
        }
    }

    /// An Apple development or distribution certificate issued to `team`.
    public static func teamRequirement(_ team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
