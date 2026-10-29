import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("React Native key pacing")
@MainActor
struct ReactNativePacingTests {
    static func app(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Sample.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            if file.hasSuffix(".framework") || file.hasSuffix(".bundle") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data().write(to: url)
            }
        }
        return root
    }

    @Test("an app bundle with React's resources, a JS bundle or a Hermes framework is React Native; a native app is not")
    func detection() throws {
        #expect(ReactNativeBundle.isReactNative(appPath: try Self.app(["main.jsbundle"]).path))
        #expect(ReactNativeBundle.isReactNative(appPath: try Self.app(["React-Core_privacy.bundle"]).path))
        #expect(ReactNativeBundle.isReactNative(appPath: try Self.app(["Frameworks/hermesvm.framework"]).path))
        #expect(!ReactNativeBundle.isReactNative(appPath: try Self.app(["Frameworks/ReactiveSwift.framework", "Assets.car"]).path))
    }

    @Test("the app in front of a simulator tree is found through its process's executable")
    func front() throws {
        let app = try Self.app(["main.jsbundle"])
        let tree = UITree(platform: .ios, device: "sim", roots: [FakeUI.node(.application, frame: FakeUI.frame(0, 0, 402, 874), pid: 4242)])
        #expect(ReactNativeBundle.isFront(in: tree) { $0 == 4242 ? app.appendingPathComponent("Sample").path : nil })
        #expect(!ReactNativeBundle.isFront(in: tree) { _ in "/usr/bin/true" })
        #expect(!ReactNativeBundle.isFront(in: nil))
    }

    @Test("paced typing waits between characters, never before the first, and types the same keys")
    func paced() throws {
        let plain = try Type.iosEvents(for: "ABC", replacing: false)
        let paced = try Type.iosEvents(for: "ABC", replacing: false, paced: true)
        #expect(paced.filter { $0 != .delay(Type.reactNativeKeyGap) } == plain)
        #expect(paced.filter { $0 == .delay(Type.reactNativeKeyGap) }.count == 2)
        #expect(paced.first != .delay(Type.reactNativeKeyGap))
        #expect(try Type.iosEvents(for: "ABC", replacing: true, paced: true).dropFirst().elementsEqual(paced))
    }
}
