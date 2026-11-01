import Foundation
import LocalAuthentication
import OffsiderCore
import Security

/// An Apple development team with a code-signing identity in the login Keychain.
struct SigningTeam: Equatable, Sendable {
    let id: String
    let name: String
    /// The email a development certificate's common name can hold, for telling teams with one name apart; shown only to the person choosing, never saved.
    var account: String?
    /// Whether Xcode calls this team free; nil when it does not say, as a certificate never does.
    var free: Bool?

    /// `Name (TEAMID)`, as the allow walkthrough lists it.
    var label: String { "\(name) (\(id))" }

    /// What the receipt calls this team: its name, plus what tells it from another team of that name.
    func shown(among teams: [SigningTeam]) -> String {
        teams.contains { $0.id != id && $0.name == name } ? "\(name) (\(account ?? id))" : name
    }
}

/// The teams the person can sign Offsider's runner with, read from the Keychain's code-signing identities.
enum SigningTeams {
    static let certificatePrefixes = ["Apple Development", "Apple Distribution", "iPhone Developer", "iPhone Distribution", "Developer ID Application"]

    /// One certificate's subject as a team; nil for a certificate that is not an Apple code-signing one or names no team.
    static func team(commonName: String?, organisationalUnit: String?, organisation: String?) -> SigningTeam? {
        guard let commonName, let prefix = certificatePrefixes.first(where: { commonName.hasPrefix($0 + ":") }) else { return nil }
        var holder = commonName.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespaces)
        var bracketed: String?
        if holder.hasSuffix(")"), let open = holder.lastIndex(of: "(") {
            bracketed = String(holder[holder.index(after: open)..<holder.index(before: holder.endIndex)])
            holder = holder[..<open].trimmingCharacters(in: .whitespaces)
        }
        // Development certificates bracket a personal ID, never the team.
        let personal = prefix == "Apple Development" || prefix == "iPhone Developer"
        guard let id = organisationalUnit ?? (personal ? nil : bracketed), DeviceAllowance.isTeamID(id) else { return nil }
        let name = organisation?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? holder.nilIfEmpty ?? id
        return SigningTeam(id: id, name: name, account: personal && isEmail(holder) && holder != name ? holder : nil)
    }

    private static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !text.contains(where: \.isWhitespace)
    }

    /// One row per team ID, keeping the first certificate's name and any certificate's email; free teams last, then by name.
    static func teams(_ subjects: [(commonName: String?, organisationalUnit: String?, organisation: String?)], xcode: [String: Bool?] = [:]) -> [SigningTeam] {
        let found = subjects.compactMap { team(commonName: $0.commonName, organisationalUnit: $0.organisationalUnit, organisation: $0.organisation) }
        return Dictionary(found.map { ($0.id, $0) }) { first, second in
            SigningTeam(id: first.id, name: first.name, account: [first.account, second.account].compactMap { $0 }.min())
        }
        .values
        .map { SigningTeam(id: $0.id, name: $0.name, account: $0.account, free: xcode[$0.id] ?? nil) }
        .sorted { first, second in
            if (first.free == true) != (second.free == true) { return second.free == true }
            let order = first.name.localizedCaseInsensitiveCompare(second.name)
            return order == .orderedSame ? first.id < second.id : order == .orderedAscending
        }
    }

    /// Reads identities only (never a private key) with interaction off, so it never prompts. No network.
    static func discover() -> [SigningTeam] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result as? [Any] else { return [] }
        let subjects = found.compactMap { item -> (String?, String?, String?)? in
            guard CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID() else { return nil }
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(item as! SecIdentity, &certificate) == errSecSuccess, let certificate else { return nil }
            return subject(of: certificate)
        }
        return teams(subjects.map { (commonName: $0.0, organisationalUnit: $0.1, organisation: $0.2) }, xcode: XcodeTeams.signedIn())
    }

    private static func subject(of certificate: SecCertificate) -> (String?, String?, String?) {
        var commonName: CFString?
        _ = SecCertificateCopyCommonName(certificate, &commonName)
        let keys = [kSecOIDX509V1SubjectName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return (commonName as String?, nil, nil)
        }
        func field(_ oid: CFString) -> String? {
            fields.first { $0[kSecPropertyKeyLabel as String] as? String == oid as String }?[kSecPropertyKeyValue as String] as? String
        }
        return (field(kSecOIDCommonName) ?? commonName as String?, field(kSecOIDOrganizationalUnitName), field(kSecOIDOrganizationName))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
