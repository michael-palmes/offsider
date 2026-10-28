import Foundation
import OffsiderAndroid
import OffsiderCore

/// The Android helper shipped in Offsider's resource bundle, read and checked once per process.
enum HelperBundle {
    static func load() throws -> HelperDex {
        try loaded.get()
    }

    private static let loaded: Result<HelperDex, HelperDexError> = Result { try read(from: Bundle.module) }
        .mapError { $0 as? HelperDexError ?? .damaged($0.localizedDescription) }

    /// Reads the dex and its manifest through the digests compiled into this build, then checks the dex against the manifest.
    static func read(from bundle: Bundle, digests: [String: String] = BundleDigests.files) throws -> HelperDex {
        guard bundle.url(forResource: "offsider-helper", withExtension: "dex", subdirectory: "helper") != nil,
              bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "helper") != nil else {
            throw HelperDexError.notBundled("helper/offsider-helper.dex or helper/manifest.json is missing from \(bundle.bundlePath)")
        }
        let bytes: Data
        let manifest: Data
        do {
            bytes = try BundleIntegrity.verifiedData("helper/offsider-helper.dex", in: bundle, digests: digests)
            manifest = try BundleIntegrity.verifiedData("helper/manifest.json", in: bundle, digests: digests)
        } catch let error as CLIError {
            throw HelperDexError.damaged(error.userFacingDescription)
        }
        return try HelperDex(bytes: bytes, manifestJSON: manifest)
    }
}

extension AndroidHost {
    /// The executable's host: the live Mac, the bundled helper and, with `OFFSIDER_TIMINGS=1`, Android phase lines.
    static func cli() -> AndroidHost {
        var host = AndroidHost.live(helperDex: { try HelperBundle.load() }, timing: Timings.android)
        host.claimDevice = { serial in try await DeviceClaims.current.claim(DeviceLockKey(platform: .android, id: serial)) }
        host.displayCacheDirectory = AndroidHost.privateDisplayCache(environment: host.environment)
        host.metroReverseDirectory = AndroidHost.privateMetroReverses()
        host.helperBroker = AndroidHost.detachedHelperBroker(environment: host.environment)
        return host
    }

    /// Brokers are this executable, started detached with `android-session serve`; sockets and logs live in the private `sessions/`.
    static func detachedHelperBroker(environment: [String: String]) -> HelperBrokerHost {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let childEnvironment = ChildEnvironment.make(.androidBroker, from: environment)
        return HelperBrokerHost(
            directory: { try OffsiderPrivateDirectory.ensureSubdirectory(sessionsDirectoryName) },
            spawn: { serial, logPath in
                try DetachedProcess().launch(
                    executable: executable, arguments: HelperBrokerHost.serveArguments(serial), environment: childEnvironment, logPath: logPath
                )
            },
            exitStatus: { DetachedProcess().exitStatus(of: $0) },
            lockRoot: OffsiderPrivateDirectory.root
        )
    }

    /// Shared with the iPhone session brokers' sockets.
    static let sessionsDirectoryName = "sessions"
}
