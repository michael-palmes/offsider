import Foundation
import OffsiderCore

/// The resumed activity and the launcher, in one adb round trip.
enum AndroidForeground {
    static let readScript = "echo top=$(dumpsys activity activities | grep -m1 -E '^ *(topResumedActivity|mResumedActivity|ResumedActivity)'); "
        + "echo home=$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -n 1)"

    static let homeIntent = "am start -a android.intent.action.MAIN -c android.intent.category.HOME"

    static func parse(_ output: String) -> ForegroundActivities {
        ForegroundActivities(
            top: AndroidAwakeState.value(of: "top", in: output).flatMap(component),
            home: AndroidAwakeState.value(of: "home", in: output).flatMap(component)
        )
    }

    /// The first `package/Class` token, with a leading-dot class expanded: `com.x/.Main` is `com.x/com.x.Main`.
    static func component(_ text: String) -> String? {
        let token = text.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" || $0 == "=" || $0 == ":" }).first { part in
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            return pieces.count == 2 && pieces.allSatisfy { piece in
                !piece.isEmpty && piece.allSatisfy { $0.isLetter || $0.isNumber || "._$".contains($0) }
            } && pieces[0].contains(".")
        }
        guard let token else { return nil }
        let pieces = String(token).components(separatedBy: "/")
        let package = pieces[0]
        let className = pieces[1].hasPrefix(".") ? package + pieces[1] : pieces[1]
        return "\(package)/\(className)"
    }
}
