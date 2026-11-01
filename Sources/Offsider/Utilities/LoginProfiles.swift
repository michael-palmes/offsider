import Foundation
import OffsiderCore

/// Finds `offsider.login.json` the same way as `OFFSIDER.md`. A missing file on the implicit walk means no profile.
enum LoginProfiles {
    /// The file for a command that only takes its app from it: none is nil, and a broken one exits 64 rather than reading as naming no app.
    static func implicit(project: String? = nil) throws -> LoginProfile? {
        try load(project: project, warn: { _ in }, outcome: "Nothing was read or sent.")
    }

    /// `warn` gets one line when the file still has the removed `turnstile` key; `outcome` ends a refusal.
    static func load(project: String?, warn: (String) -> Void = removedKeyWarning, outcome: String = "Nothing was typed.") throws -> LoginProfile? {
        let found: ProjectGuide.Found
        do {
            if let project {
                found = try ProjectGuide.locate(fileName: LoginProfile.fileName, from: project)
            } else {
                found = try ProjectGuide.locate(fileName: LoginProfile.fileName, from: FileManager.default.currentDirectoryPath)
            }
        } catch let error as ProjectGuide.Failure {
            if case .notFound = error, project == nil { return nil }
            throw CLIError(errorDescription: "\(message(error)) \(outcome)", reason: .usage)
        }
        do {
            let profile = try LoginProfile.parse(Data(found.text.utf8))
            if profile.hasRemovedTurnstileKey { warn(LoginProfile.removedTurnstileWarning) }
            return profile
        } catch let error as LoginProfileError {
            throw CLIError(errorDescription: "\(error.message) \(outcome)", reason: .usage)
        }
    }

    /// An agent reads the line as it always has; a person a warning naming the key to remove.
    private static func removedKeyWarning(_ line: String) {
        Console.current.line(line, person: .warning("offsider.login.json has a `turnstile` key, which login ignores: remove it"))
    }

    private static func message(_ failure: ProjectGuide.Failure) -> String {
        switch failure {
        case .missingPath(let path):
            return "No such directory \(path)."
        case .notFound(_, let stop):
            return "No offsider.login.json in \(stop)."
        case .unreadable(let path, let detail):
            return "Could not read \(path): \(detail)."
        }
    }
}
