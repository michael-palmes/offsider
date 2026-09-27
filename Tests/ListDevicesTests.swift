import Testing
import Foundation

@Suite("List Devices Command Tests", .enabled(if: isE2EEnabled))
struct ListDevicesTests {
    @Test("Basic list-devices prints the header and rows")
    func basicListDevices() async throws {
        // Act
        let result = try await TestHelpers.runOffsiderCommand("list-devices")
        
        // Assert
        #expect(result.exitCode == 0, "Exit code should be 0")
        #expect(result.output.hasPrefix("PLATFORM  STATE"), "Output should start with the header")
        #expect(
            result.output.contains("iOS") ||
            result.output.contains("Shutdown") ||
            result.output.contains("Booted")
        )
    }
    
    @Test("List devices includes UDID")
    func listDevicesIncludesUDID() async throws {
        // Act
        let result = try await TestHelpers.runOffsiderCommand("list-devices")
        
        // Assert - Should contain UUID pattern
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let regex = try NSRegularExpression(pattern: uuidPattern, options: .caseInsensitive)
        let matches = regex.matches(in: result.output, range: NSRange(result.output.startIndex..., in: result.output))
        
        #expect(matches.count > 0, "Should find at least one simulator UDID")
    }
    
    @Test("List devices includes device names")
    func listDevicesIncludesDeviceNames() async throws {
        // Act
        let result = try await TestHelpers.runOffsiderCommand("list-devices")
        
        // Assert - Should contain common device names
        let commonDevicePatterns = ["iPhone", "iPad", "Apple Watch", "Apple TV"]
        var foundAnyDevice = false
        
        for pattern in commonDevicePatterns {
            if result.output.contains(pattern) {
                foundAnyDevice = true
                break
            }
        }
        
        #expect(foundAnyDevice, "Should find at least one device name")
    }
    
    @Test("List devices includes OS versions")
    func listDevicesIncludesOSVersions() async throws {
        // Act
        let result = try await TestHelpers.runOffsiderCommand("list-devices")
        
        // Assert - Should contain OS version patterns
        let osPatterns = ["iOS [0-9]+\\.[0-9]+", "watchOS [0-9]+\\.[0-9]+", "tvOS [0-9]+\\.[0-9]+"]
        var foundOSVersion = false
        
        for pattern in osPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: result.output, range: NSRange(result.output.startIndex..., in: result.output)) != nil {
                foundOSVersion = true
                break
            }
        }
        
        #expect(foundOSVersion, "Should find at least one OS version")
    }
    
    @Test("List devices shows device status")
    func listDevicesShowsStatus() async throws {
        // Act
        let result = try await TestHelpers.runOffsiderCommand("list-devices")
        
        // Assert - Should show status (Booted or Shutdown)
        let hasStatus = result.output.contains("Booted") || result.output.contains("Shutdown")
        #expect(hasStatus, "Should show simulator status")
    }
    
    @Test("Every row names its platform")
    func listDevicesRowsNamePlatform() async throws {
        let result = try await TestHelpers.runOffsiderCommand("list-devices")

        let rows = result.output.components(separatedBy: .newlines).dropFirst().filter { !$0.isEmpty }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.hasPrefix("ios ") })
    }

    @Test("JSON lists the test simulator with every key")
    func listDevicesJSONIncludesTestSimulator() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let result = try await TestHelpers.runOffsiderCommandSeparated("list-devices --json")
        #expect(result.exitCode == 0)

        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let devices = try #require(object["devices"] as? [[String: Any]])
        let device = try #require(devices.first { $0["id"] as? String == udid })

        #expect(object["version"] as? Int == 1)
        #expect(Set(device.keys) == ["id", "platform", "state", "name", "osVersion", "deviceType"])
        #expect(device["platform"] as? String == "ios")
        #expect(device["state"] as? String == "Booted")
        #expect((device["osVersion"] as? String)?.hasPrefix("iOS ") == true)
    }

    @Test("--platform ios lists the same devices as no filter")
    func platformIOSMatchesUnfiltered() async throws {
        let all = try await TestHelpers.runOffsiderCommand("list-devices")
        let ios = try await TestHelpers.runOffsiderCommand("list-devices --platform ios")

        #expect(ios.output == all.output)
    }

    @Test("A lowercase device ID reaches the same simulator")
    func lowercaseDeviceIDRoutes() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("describe-ui --device \(udid.lowercased())")

        #expect(result.exitCode == 0, "describe-ui failed: \(result.output)")
        let envelope = try UIStateParser.parseDescribeUIEnvelope(result.output)
        #expect(!envelope.roots.isEmpty)
        #expect(envelope.device == udid.uppercased())
    }
}
