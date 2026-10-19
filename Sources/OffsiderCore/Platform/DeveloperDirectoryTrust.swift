import Darwin
import Foundation
import Security

/// Where the developer directory came from.
public enum DeveloperDirectorySource: String, Equatable, Sendable {
    case environment = "DEVELOPER_DIR"
    case xcodeSelect = "xcode-select"

    public static func of(environment: [String: String]) -> DeveloperDirectorySource {
        (environment["DEVELOPER_DIR"] ?? "").isEmpty ? .xcodeSelect : .environment
    }
}

/// A developer directory inside an Apple-signed Xcode, with symlinks resolved.
public struct TrustedDeveloperDirectory: Equatable, Sendable {
    public let resolved: String
    public let app: String

    public init(resolved: String, app: String) {
        self.resolved = resolved
        self.app = app
    }

    public var inApplications: Bool { app.hasPrefix("/Applications/") }
}

/// The developer directory is not inside an Apple-signed Xcode, so Offsider loads nothing from it and runs no tool in it.
public struct UntrustedDeveloperDirectory: OffsiderFailure, LocalizedError, Equatable, Sendable {
    public enum Problem: String, Error, Equatable, Sendable {
        /// Missing, or not `<name>.app/Contents/Developer` once symlinks are resolved.
        case notInAppBundle
        /// Validly signed, but not by Apple, or not as Xcode.
        case notAppleSigned
        case unsigned
        /// Signed, but its executable or `Info.plist` no longer matches the signature.
        case modified

        /// Why, after the path: "<path> is not ...".
        public var summary: String {
            switch self {
            case .notInAppBundle: return "is not the Contents/Developer folder of an Xcode app"
            case .notAppleSigned: return "is in an app that Apple did not sign as Xcode"
            case .unsigned: return "is in an app with no code signature"
            case .modified: return "is in an app changed since it was signed"
            }
        }
    }

    public let path: String
    public let source: DeveloperDirectorySource
    public let problem: Problem

    public init(path: String, source: DeveloperDirectorySource, problem: Problem) {
        self.path = path
        self.source = source
        self.problem = problem
    }

    public var reason: FailureReason { .xcodeUnusable }
    public var failureMessage: String {
        XcodeSuggestion.instead(of: path).adding(
            to: "\(source.rawValue) points at \(path), which \(problem.summary), so Offsider will not load simulator frameworks or run Xcode tools from it."
        )
    }
    public var hint: String? { XcodeSuggestion.instead(of: path).select }
    public var errorDescription: String? { failureMessage }
}

/// Checks that a developer directory is `<Xcode>.app/Contents/Developer` and that Apple signed the app as Xcode; answers are cached per process by resolved path.
public final class DeveloperDirectoryTrust: @unchecked Sendable {
    /// nil when the app at the path is trusted, else why not.
    public typealias Validator = @Sendable (_ appPath: String) -> UntrustedDeveloperDirectory.Problem?

    /// Apple's own signature, as on Xcode from developer.apple.com.
    public static let appleRequirement = "anchor apple"
    /// The Mac App Store signs Xcode's app wrapper with its own certificate, never as `anchor apple`; the code inside stays Apple's own.
    public static let appStoreXcode = #"anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists and identifier "com.apple.dt.Xcode""#
    /// Apple's team on Xcode from the Mac App Store, read from the signature because the store's certificate names no team.
    public static let appStoreXcodeTeam = "59GAB85EFG"
    public static let shared = DeveloperDirectoryTrust()

    /// The app's main executable and Info.plist only; validating Xcode's resources would take seconds.
    public static func check(_ app: String, appStoreTeam: String = appStoreXcodeTeam) -> UntrustedDeveloperDirectory.Problem? {
        do {
            try CodeSignatureCheck.validate(path: app, requirement: appleRequirement, resources: false)
            return nil
        } catch let failure as CodeSignatureCheck.Failure where failure.status == errSecCSReqFailed {
            let team = try? CodeSignatureCheck.validate(path: app, requirement: appStoreXcode, resources: false)
            return team == appStoreTeam ? nil : .notAppleSigned
        } catch let failure as CodeSignatureCheck.Failure where failure.status == errSecCSUnsigned {
            return .unsigned
        } catch {
            return .modified
        }
    }

    public static let appleSigned: Validator = { check($0) }

    private let validator: Validator
    private let lock = NSLock()
    private var cache: [String: Result<TrustedDeveloperDirectory, UntrustedDeveloperDirectory.Problem>] = [:]

    public init(validator: @escaping Validator = DeveloperDirectoryTrust.appleSigned) {
        self.validator = validator
    }

    /// `path` with symlinks resolved, or nil when it does not exist.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The `.app` that holds `resolved` as its `Contents/Developer`, or nil for any other shape.
    public static func appBundle(of resolved: String) -> String? {
        let components = (resolved as NSString).pathComponents
        guard components.count >= 4, components[components.count - 1] == "Developer", components[components.count - 2] == "Contents",
              components[components.count - 3].hasSuffix(".app"), components[components.count - 3].count > 4 else { return nil }
        return NSString.path(withComponents: Array(components.dropLast(2)))
    }

    public func evaluate(_ path: String) -> Result<TrustedDeveloperDirectory, UntrustedDeveloperDirectory.Problem> {
        guard let resolved = Self.realPath(path) else { return .failure(.notInAppBundle) }
        if let cached = lock.withLock({ cache[resolved] }) { return cached }
        let result: Result<TrustedDeveloperDirectory, UntrustedDeveloperDirectory.Problem>
        if let app = Self.appBundle(of: resolved) {
            result = validator(app).map { .failure($0) } ?? .success(TrustedDeveloperDirectory(resolved: resolved, app: app))
        } else {
            result = .failure(.notInAppBundle)
        }
        lock.withLock { cache[resolved] = result }
        return result
    }

    @discardableResult
    public func require(_ path: String, source: DeveloperDirectorySource) throws -> TrustedDeveloperDirectory {
        switch evaluate(path) {
        case .success(let trusted): return trusted
        case .failure(let problem): throw UntrustedDeveloperDirectory(path: path, source: source, problem: problem)
        }
    }
}
