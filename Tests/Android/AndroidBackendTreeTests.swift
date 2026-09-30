import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android backend tree")
@MainActor
struct AndroidBackendTreeTests {
    nonisolated static func dump(rotation: Int) -> String {
        """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="\(rotation)"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="p" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][1080,2424]" hint=""><node index="0" text="" resource-id="BackButton" class="android.widget.Button" package="p" content-desc="Offsider Playground" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[21,142][137,258]" hint="" /></node></hierarchy>
        """
    }

    static func server(dump: FakeAdbServer.Reply) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in
                if service.hasSuffix(AndroidDisplayGeometry.probeScript) {
                    return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput)
                }
                return service.contains("uiautomator dump") ? dump : FakeAdbServer.shell(status: 1)
            }
        ))
    }

    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    @Test("the tree comes from a uniquely named uiautomator dump, mapped to dp")
    func tree() async throws {
        let server = Self.server(dump: FakeAdbServer.shell(stdout: Self.dump(rotation: 0)))
        let tree = try await AndroidBackendTests.backend(server).accessibilityTree(for: Self.device, point: nil)

        #expect(tree.platform == .android)
        #expect(tree.screen == nil)
        #expect(tree.roots.first?.role == .application)
        #expect(tree.roots.first?.children.first?.frame == UIFrame(x: 8, y: 54.1, width: 44.19, height: 44.19))
        #expect(server.services.contains { $0.contains("/data/local/tmp/offsider-ui-\(getpid())-1.xml") })
    }

    @Test("with a point, the deepest node there is the only root")
    func point() async throws {
        let server = Self.server(dump: FakeAdbServer.shell(stdout: Self.dump(rotation: 0)))
        let tree = try await AndroidBackendTests.backend(server).accessibilityTree(for: Self.device, point: UIPoint(x: 20, y: 70))
        #expect(tree.roots.map(\.id) == ["BackButton"])
    }

    @Test("a busy UiAutomation slot is an actionable error")
    func busy() async throws {
        let backend = try AndroidBackendTests.backend(Self.server(dump: FakeAdbServer.shell(status: 137)))
        let error = await #expect(throws: AndroidError.self) { try await backend.accessibilityTree(for: Self.device, point: nil) }
        #expect(error?.kind == .uiautomatorBusy)
        #expect(error?.message.contains("Another UiAutomation client") == true)
    }

    @Test("the dump's rotation refreshes the cached geometry without another probe")
    func rotationRefresh() async throws {
        let server = Self.server(dump: FakeAdbServer.shell(stdout: Self.dump(rotation: 1)))
        let backend = try AndroidBackendTests.backend(server)
        _ = try await backend.accessibilityTree(for: Self.device, point: nil)
        let info = try await backend.screenInfo(for: Self.device)

        #expect(info == UIScreenInfo(width: 923.43, height: 411.43, scale: 2.625, orientation: .landscapeFlipped))
        #expect(server.services.filter { $0.hasSuffix(AndroidDisplayGeometry.probeScript) }.count == 1)
    }

    @Test("a dump that never answers names uiautomator, not the whole script")
    func dumpTimeout() async throws {
        let backend = try AndroidBackendTests.backend(Self.server(dump: FakeAdbServer.okay))
        let error = await #expect(throws: AndroidError.self) { try await backend.accessibilityTree(for: Self.device, point: nil) }
        #expect(error?.message == "`uiautomator dump` failed on emulator-5556: no answer within 20 s.")
    }
}
