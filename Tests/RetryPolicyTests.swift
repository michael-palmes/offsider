import Testing
import OffsiderCore

@Suite("Retry Policy Tests")
struct RetryPolicyTests {
    @Test("One retry from simulator style switches to physical")
    func oneRetryAlternates() {
        #expect(RetryPolicy.tapStyles(initial: .simulator, retries: 1) == [.simulator, .physical])
    }

    @Test("Three retries from physical style keep alternating")
    func threeRetriesAlternate() {
        #expect(RetryPolicy.tapStyles(initial: .physical, retries: 3) == [.physical, .simulator, .physical, .simulator])
    }

    @Test("Zero retries means a single attempt")
    func zeroRetries() {
        #expect(RetryPolicy.attemptCount(retries: 0) == 1)
        #expect(RetryPolicy.tapStyles(initial: .simulator, retries: 0) == [.simulator])
    }

    @Test("The documented limits: default 1, allowed 0 to 3")
    func limits() {
        #expect(RetryPolicy.defaultRetries == 1)
        #expect(RetryPolicy.allowedRetries == 0...3)
    }
}
