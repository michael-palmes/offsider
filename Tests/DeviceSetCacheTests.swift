import Testing
@testable import Offsider

@Suite("Device set cache")
@MainActor
struct DeviceSetCacheTests {
    private final class Factory {
        var builds = 0
        var devicesPerBuild: [[String]]

        init(_ devicesPerBuild: [[String]]) {
            self.devicesPerBuild = devicesPerBuild
        }

        func build() -> [String] {
            builds += 1
            return devicesPerBuild.isEmpty ? [] : devicesPerBuild.removeFirst()
        }
    }

    @Test("Two lookups of a known device build the set once")
    func hitsShareOneBuild() {
        let cache = DeviceSetCache<[String]>()
        let factory = Factory([["A", "B"]])

        let first = cache.lookup(deviceSetPath: nil, build: factory.build) { $0.first { $0 == "A" } }
        let second = cache.lookup(deviceSetPath: nil, build: factory.build) { $0.first { $0 == "B" } }

        #expect(first == "A")
        #expect(second == "B")
        #expect(factory.builds == 1)
    }

    @Test("A miss rebuilds once, finds a device that appeared, and keeps the new set")
    func missRebuildsOnce() {
        let cache = DeviceSetCache<[String]>()
        let factory = Factory([["A"], ["A", "NEW"]])

        _ = cache.lookup(deviceSetPath: nil, build: factory.build) { $0.first { $0 == "A" } }
        let found = cache.lookup(deviceSetPath: nil, build: factory.build) { $0.first { $0 == "NEW" } }
        let again = cache.lookup(deviceSetPath: nil, build: factory.build) { $0.first { $0 == "NEW" } }

        #expect(found == "NEW")
        #expect(again == "NEW")
        #expect(factory.builds == 2)
    }

    @Test("A device that never appears rebuilds once per lookup, then reports nothing")
    func persistentMissReturnsNil() {
        let cache = DeviceSetCache<[String]>()
        let factory = Factory([["A"], ["A"]])

        let missing = cache.lookup(deviceSetPath: nil, build: factory.build) { $0.first { $0 == "GONE" } }

        #expect(missing == nil)
        #expect(factory.builds == 2)
    }

    @Test("Each device-set path has its own set")
    func setsAreKeyedByPath() {
        let cache = DeviceSetCache<[String]>()
        let factory = Factory([["default"], ["custom"]])

        let defaultSet = cache.set(deviceSetPath: nil, build: factory.build)
        let customSet = cache.set(deviceSetPath: "/tmp/custom-set", build: factory.build)
        let defaultAgain = cache.set(deviceSetPath: nil, build: factory.build)

        #expect(defaultSet == ["default"])
        #expect(customSet == ["custom"])
        #expect(defaultAgain == ["default"])
        #expect(factory.builds == 2)
    }
}
