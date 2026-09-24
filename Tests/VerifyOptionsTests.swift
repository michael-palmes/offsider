import Foundation
import Testing

@Suite("Verify Options Tests")
struct VerifyOptionsTests {
    private static let fakeUDID = "00000000-0000-0000-0000-000000000000"

    private func run(_ command: String) async throws -> SeparatedCommandOutput {
        try await TestHelpers.runOffsiderCommandSeparated("\(command) --udid \(Self.fakeUDID)")
    }

    @Test("--retries without --verify is a usage error")
    func retriesRequireVerify() async throws {
        let result = try await run("tap -x 1 -y 1 --retries 2")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("require --verify"))
        #expect(result.stdout.isEmpty)
    }

    @Test("--json without --verify is a usage error")
    func jsonRequiresVerify() async throws {
        let result = try await run("key 40 --json")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("require --verify"))
        #expect(result.stdout.isEmpty)
    }

    @Test("--retries above 3 is a usage error")
    func retriesOutOfRange() async throws {
        let result = try await run("type hello --verify --retries 4")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("--retries must be between 0 and 3"))
    }

    @Test("--verify-timeout below half a second is a usage error")
    func timeoutOutOfRange() async throws {
        let result = try await run("button home --verify --verify-timeout 0")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("--verify-timeout must be between 0.5 and 30 seconds"))
    }

    @Test("Batch steps reject --verify before any simulator access")
    func batchRejectsVerify() async throws {
        let result = try await run("batch --step \"tap -x 1 -y 1 --verify\"")
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Batch steps do not support --verify"))
        #expect(!result.stderr.contains("No simulator with UDID"))
    }

    @Test("Batch steps reject the --retries=N form too")
    func batchRejectsEqualsForm() async throws {
        let result = try await run("batch --step \"key 40\" --step \"type hi --retries=2\"")
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Batch steps do not support --verify"))
    }
}
