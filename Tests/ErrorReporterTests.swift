import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Error reporter")
struct ErrorReporterTests {
    @Test("the Error line escapes control and bidi characters and indents continuation lines")
    func errorText() {
        #expect(ErrorReporter.errorText("No element matched.") == "Error: No element matched.\n")
        #expect(ErrorReporter.errorText("Step 1 failed\nError: forged \u{1B}]52;c;eA==\u{07}\u{202E}") == "Error: Step 1 failed\n  Error: forged \\u001b]52;c;eA==\\u0007\\u202e\n")
        #expect(ErrorReporter.errorText("list:\n  - kept") == "Error: list:\n  - kept\n")
    }
}
