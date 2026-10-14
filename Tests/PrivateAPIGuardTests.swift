import Foundation
import OffsiderCore
import Testing

@Suite("Private API guard")
struct PrivateAPIGuardTests {
    @Test("frame offsets are ignored when comparing type encodings")
    func stripped() {
        #expect(PrivateAPIGuard.strippedEncoding("@28@0:8@16I24") == "@@:@I")
        #expect(PrivateAPIGuard.strippedEncoding("I32@0:8@16^@24") == "I@:@^@")
    }

    @Test("a method whose types match passes; a changed or missing one fails as xcode_unusable naming the selector")
    func requireMethod() throws {
        try PrivateAPIGuard.requireMethod(NSString.self, NSSelectorFromString("length"), encoding: "Q16@0:8", framework: "Foundation")
        let changed = #expect(throws: PrivateAPIChanged.self) {
            try PrivateAPIGuard.requireMethod(NSString.self, NSSelectorFromString("length"), encoding: "I@:", framework: "SimulatorKit")
        }
        #expect(changed?.reason == .xcodeUnusable)
        #expect(changed?.failureMessage == "This Xcode's SimulatorKit changed length; update Offsider.")
        #expect(throws: PrivateAPIChanged.self) {
            try PrivateAPIGuard.requireMethod(NSString.self, NSSelectorFromString("noSuchSelector"), encoding: "v@:", framework: "SimulatorKit")
        }
    }
}
