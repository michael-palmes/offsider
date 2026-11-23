import Foundation
import Synchronization
@testable import OffsiderIOSDevice

/// The runner prefix seal without the Keychain, so no test writes a login item or raises a prompt.
final class InMemoryRunnerPrefixSeal: RunnerPrefixSealing {
    private let digest = Mutex<Data?>(nil)

    func storedDigest() throws -> Data? { digest.withLock { $0 } }
    func store(digest: Data) throws { self.digest.withLock { $0 = digest } }
}
