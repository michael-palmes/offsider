import Foundation
import OffsiderCore

/// Who started the activity in front, as `dumpsys activity activities` records it: Android's own answer to which app a permission dialog is for.
struct AndroidPromptOwner: Equatable, Sendable {
    /// The resumed activity, `package/Class`.
    var component: String
    /// The record's token, which changes when another activity takes its place.
    var token: String
    /// The uid of the caller that started it, from Binder, which an app cannot choose.
    var launchedFromUid: Int?
    var launchedFromPackage: String?
    /// The intent's action, such as `android.content.pm.action.REQUEST_PERMISSIONS`.
    var action: String?

    static let requestPermissions = "android.content.pm.action.REQUEST_PERMISSIONS"

    /// The resumed activity's history record and the named app's uid, in one adb round trip; `app` is a checked package name.
    static func readScript(app: String) -> String {
        "echo uid=$(dumpsys package \(app) | grep -m1 -E '^ +(userId|appId)='); " + ownerScript
    }

    /// The resumed activity's history record alone, for when the app's uid is already known.
    static let ownerScript = "dumpsys activity activities | grep -E -A6 '^ *(\\* Hist +#[0-9]+: ActivityRecord\\{|topResumedActivity|mResumedActivity|ResumedActivity)'"

    /// The owner of the resumed activity and the app's uid; nil where the dump does not say.
    static func parse(_ output: String) -> (owner: AndroidPromptOwner?, appUID: Int?) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let uid = lines.first { $0.hasPrefix("uid=") }.flatMap { integer(after: "userId=", in: $0) ?? integer(after: "appId=", in: $0) }
        guard let top = lines.first(where: { resumedPrefixes.contains(where: $0.hasPrefix) }), let token = recordToken(in: top),
              let component = AndroidForeground.component(top) else { return (nil, uid) }
        var owner = AndroidPromptOwner(component: component, token: token)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("* Hist") && recordToken(in: $0) == token }) else { return (owner, uid) }
        for line in lines[(start + 1)...].prefix(6) {
            if line.hasPrefix("* Hist") || resumedPrefixes.contains(where: line.hasPrefix) || line == "--" { break }
            if line.hasPrefix("launchedFromUid=") {
                owner.launchedFromUid = integer(after: "launchedFromUid=", in: line)
                owner.launchedFromPackage = word(after: "launchedFromPackage=", in: line)
            }
            if line.hasPrefix("Intent {") { owner.action = word(after: "act=", in: line) }
        }
        return (owner, uid)
    }

    private static let resumedPrefixes = ["topResumedActivity", "mResumedActivity", "ResumedActivity"]

    /// `122893975` of `ActivityRecord{122893975 u0 com.x/.Main t308}`.
    private static func recordToken(in line: String) -> String? {
        guard let open = line.range(of: "ActivityRecord{") else { return nil }
        let token = line[open.upperBound...].prefix { $0.isHexDigit }
        return token.isEmpty ? nil : String(token)
    }

    private static func word(after key: String, in line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let word = line[range.upperBound...].prefix { !$0.isWhitespace && $0 != "}" }
        return word.isEmpty || word == "null" ? nil : String(word)
    }

    private static func integer(after key: String, in line: String) -> Int? {
        word(after: key, in: line).flatMap { Int($0.prefix { $0.isNumber }) }
    }

    /// Why the activity in front is not a permission dialog `app` raised; nil when it is.
    func refusal(for app: String, appUID: Int?) -> AppPromptRefusal? {
        let package = component.split(separator: "/").first.map(String.init) ?? component
        guard SystemAppDenyList.isPermissionDialog(package, platform: .android) else {
            return .notShown(front: package)
        }
        guard action == Self.requestPermissions else {
            return .notPermission(what: "\(package), which is not asking for a runtime permission")
        }
        guard let launchedFromPackage, let launchedFromUid else {
            return .otherApp(requester: nil, why: "Android did not say which app raised it")
        }
        guard launchedFromPackage == app else {
            return .otherApp(requester: launchedFromPackage, why: "\(launchedFromPackage) raised it")
        }
        guard let appUID, appUID == launchedFromUid else {
            return .otherApp(requester: nil, why: "the caller's uid (\(launchedFromUid)) is not \(app)'s")
        }
        return nil
    }
}
