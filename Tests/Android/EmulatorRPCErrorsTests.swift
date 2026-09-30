import Foundation
import GRPCCore
import Testing
@testable import OffsiderAndroid

@Suite("Emulator gRPC errors")
struct EmulatorRPCErrorsTests {
    static let discovery = try! EmulatorDiscovery.parse(fileName: "pid_50144.ini", contents: """
    avd.id=Offsider_E2E_Pixel_9
    port.serial=5556
    grpc.port=8556
    grpc.token=s3cr3t-token
    grpc.allowlist=/sdk/emulator/lib/emulator_access.json
    """)

    static func map(_ code: RPCError.Code, _ message: String = "", method: EmulatorMethod = .sendTouch, issuer: String = "gradle-utp-emulator-control") -> AndroidError {
        EmulatorRPCErrors.map(RPCError(code: code, message: message), method: method, endpoint: "127.0.0.1:8556", discovery: discovery, issuer: issuer, timeout: .seconds(2))
    }

    @Test("unauthenticated says the credentials were rejected for the method and how to get fresh ones")
    func unauthenticated() {
        #expect(Self.map(.unauthenticated, "Missing the 'authorization' header").message == "The emulator's gRPC endpoint (127.0.0.1:8556) rejected Offsider's credentials for `sendTouch`. Restart the emulator with `offsider boot Offsider_E2E_Pixel_9` so it issues fresh credentials.")
    }

    @Test("permissionDenied names the allowlist, the issuer and the method")
    func permissionDenied() {
        #expect(Self.map(.permissionDenied, method: .streamScreenshot).message == "The emulator's gRPC allowlist (`/sdk/emulator/lib/emulator_access.json`) does not let issuer gradle-utp-emulator-control call `streamScreenshot`. Restart the emulator with `offsider boot Offsider_E2E_Pixel_9` so it offers a token.")
    }

    @Test("unavailable names the port and both loopback addresses")
    func unavailable() {
        #expect(Self.map(.unavailable).message == "The emulator's gRPC endpoint on port 8556 did not answer on 127.0.0.1 or [::1]; it may be shutting down.")
    }

    @Test("deadlineExceeded names the method and its timeout")
    func deadline() {
        #expect(Self.map(.deadlineExceeded, method: .sendKey).message == "The emulator did not answer `sendKey` within 2 s. It may be overloaded; retry, or check it with `offsider list-devices`.")
    }

    @Test("other codes keep the emulator's message but never the token", arguments: [RPCError.Code.internalError, .invalidArgument, .unimplemented])
    func otherCodesRedactToken(code: RPCError.Code) {
        let error = Self.map(code, "bad header Bearer s3cr3t-token")
        #expect(error.kind == .grpcFailed)
        #expect(error.message.contains("bad header Bearer <redacted>"))
        #expect(!error.message.contains("s3cr3t"))
    }
}
