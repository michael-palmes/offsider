import Foundation

/// The teams of Xcode's signed-in accounts, from its local preferences; account names never leave this type.
public enum XcodeTeams {
    /// Xcode 27's key, then the one older versions wrote.
    static let keys = ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"]

    /// Each team ID and whether Xcode calls it free; nil when it does not say.
    public static func parse(_ accounts: [String: Any]) -> [String: Bool?] {
        var teams: [String: Bool?] = [:]
        for team in accounts.values.compactMap({ $0 as? [[String: Any]] }).joined() {
            guard let id = team["teamID"] as? String else { continue }
            teams[id] = team["isFreeProvisioningTeam"] as? Bool
        }
        return teams
    }

    public static func signedIn() -> [String: Bool?] {
        let defaults = UserDefaults(suiteName: "com.apple.dt.Xcode")
        guard let accounts = keys.lazy.compactMap({ defaults?.dictionary(forKey: $0) }).first else { return [:] }
        return parse(accounts)
    }
}
