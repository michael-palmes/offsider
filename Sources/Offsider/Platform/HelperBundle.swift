import Foundation
import OffsiderAndroid

/// The Android helper shipped in Offsider's resource bundle, read and checked once per process.
enum HelperBundle {
    static func load() throws -> HelperDex {
        try loaded.get()
    }

    private static let loaded: Result<HelperDex, HelperDexError> = Result { try read(from: Bundle.module) }
        .mapError { $0 as? HelperDexError ?? .damaged($0.localizedDescription) }

    static func read(from bundle: Bundle) throws -> HelperDex {
        guard let dexURL = bundle.url(forResource: "offsider-helper", withExtension: "dex", subdirectory: "helper"),
              let manifestURL = bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "helper") else {
            throw HelperDexError.notBundled("helper/offsider-helper.dex or helper/manifest.json is missing from \(bundle.bundlePath)")
        }
        let bytes: Data
        let manifest: Data
        do {
            bytes = try Data(contentsOf: dexURL)
            manifest = try Data(contentsOf: manifestURL)
        } catch {
            throw HelperDexError.notBundled("could not read \(dexURL.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        return try HelperDex(bytes: bytes, manifestJSON: manifest)
    }
}

extension AndroidHost {
    /// The executable's host: the live Mac plus the bundled helper.
    static func cli() -> AndroidHost {
        .live(helperDex: { try HelperBundle.load() })
    }
}
