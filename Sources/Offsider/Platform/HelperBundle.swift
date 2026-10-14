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
        return host
    }
}
