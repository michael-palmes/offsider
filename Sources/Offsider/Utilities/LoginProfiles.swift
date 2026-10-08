import Foundation
import OffsiderCore

/// Finds `offsider.login.json` the same way as `OFFSIDER.md`. A missing file on the implicit walk means no profile.
enum LoginProfiles {
    static func load(project: String?) throws -> LoginProfile? {
        let found: ProjectGuide.Found
        do {
            if let project {
                found = try ProjectGuide.locate(fileName: LoginProfile.fileName, from: project)
            } else {
                found = try ProjectGuide.locate(fileName: LoginProfile.fileName, from: FileManager.default.currentDirectoryPath)
            }
        } catch let error as ProjectGuide.Failure {
            if case .notFound = error, project == nil { return nil }
            throw CLIError(errorDescription: message(error), reason: .usage)
        }
        do {
            return try LoginProfile.parse(Data(found.text.utf8))
        } catch let error as LoginProfileError {
            throw CLIError(errorDescription: "\(error.message) Nothing was typed.", reason: .usage)
        }
    }

    /// The flag wins, then the profile, then `auto`.
    static func mode(flag: LoginTurnstileMode?, profile: LoginProfile?) -> LoginTurnstileMode {
        flag ?? profile?.turnstile ?? .auto
    }

    private static func message(_ failure: ProjectGuide.Failure) -> String {
        switch failure {
        case .missingPath(let path):
            return "No such directory \(path). Nothing was typed."
        case .notFound(_, let stop):
            return "No offsider.login.json in \(stop). Nothing was typed."
        case .unreadable(let path, let detail):
            return "Could not read \(path): \(detail). Nothing was typed."
        }
    }
}
