import CoreGraphics
import Foundation
import ImageIO
import Testing

extension AndroidE2E {
    /// The two ways input reaches a phone; each phone input test runs once per mode with the same assertion.
    static let inputModes = ["input", "helper"]

    static func inputMode(_ mode: String) -> [String: String] {
        ["OFFSIDER_ANDROID_INPUT": mode]
    }

    /// Runs `body` with stay-awake on and the screen woken, then puts the phone's stay-awake setting back.
    static func onAwakePhone(_ body: () async throws -> Void) async throws {
        let restore = try await AndroidDeviceStateE2ETests.stayOnRestore()
        do {
            try await run("stay-awake on")
            try await run("wake")
            try await body()
        } catch {
            _ = try? await shell(restore)
            throw error
        }
        try await shell(restore)
    }

    /// The `x:<n>,y:<n>` value of the tap-test location readout.
    static func tapLocation() async throws -> (x: Int, y: Int) {
        let node = try await waitForNode { $0["id"] as? String == "last-tap-coordinates" }
        let numbers = ((node["value"] as? String) ?? "").split(separator: ",").compactMap { Int($0.split(separator: ":").last ?? "") }
        guard numbers.count == 2 else { throw AndroidE2EError(description: "last-tap-coordinates has no x and y: \(node)") }
        return (numbers[0], numbers[1])
    }

    /// Lines of `ps -A` that belong to an Offsider helper, by nice name or main class.
    static func helperProcesses() async throws -> [String] {
        try await shell("ps -A -o PID,ARGS || true").split(whereSeparator: \.isNewline).map(String.init).filter {
            $0.contains("offsider-helper") || $0.contains("com.mpalmes.offsider.helper")
        }
    }

    /// Phase names from `OFFSIDER_TIMINGS=1` stderr.
    static func timingPhases(_ stderr: String) -> [String] {
        stderr.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ")
            guard line.hasPrefix("offsider timing: "), parts.count == 5 else { return nil }
            return String(parts[2])
        }
    }

    static func pngSize(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw AndroidE2EError(description: "\(url.lastPathComponent) is not a PNG ImageIO can read")
        }
        return (width, height)
    }

    /// The RGB of one pixel of a PNG.
    static func pixel(at url: URL, x: Int, y: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AndroidE2EError(description: "\(url.lastPathComponent) is not a PNG ImageIO can read")
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        }
        return Array(bytes.prefix(3))
    }

    static func screenshot(_ name: String, flags: String = "", environment: [String: String]? = nil) async throws -> URL {
        let output = temporaryFile(name)
        try await run("screenshot \(flags) --output \(quote(output.path))", environment: environment)
        return output
    }
}

@Suite("Android phone input", .serialized, .enabled(if: isAndroidPhoneE2EEnabled))
struct AndroidPhoneInputTests {
    @Test("a coordinate tap lands at the dp point", arguments: AndroidE2E.inputModes)
    func coordinates(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            let point = try await AndroidE2E.centre(of: "tap-test-area")
            try await AndroidE2E.run("tap -x \(point.x) -y \(point.y)", environment: AndroidE2E.inputMode(mode))
            _ = try await AndroidE2E.waitForLabel(of: "tap-count") { $0 == "Tap Count: 1" }
            let landed = try await AndroidE2E.tapLocation()
            #expect(abs(landed.x - point.x) <= 1 && abs(landed.y - point.y) <= 1, "tapped \(point), the app saw \(landed)")
        }
    }

    @Test("--id taps the element, in both tap styles", arguments: AndroidE2E.inputModes, ["simulator", "physical"])
    func byID(mode: String, style: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            try await AndroidE2E.run("tap --id tap-test-area --tap-style \(style)", environment: AndroidE2E.inputMode(mode))
            _ = try await AndroidE2E.waitForLabel(of: "tap-count") { $0 == "Tap Count: 1" }
        }
    }

    @Test("a swipe up is seen as one swipe up", arguments: AndroidE2E.inputModes)
    func swipe(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("swipe-test", waitingFor: "swipe-test-area")
            let point = try await AndroidE2E.centre(of: "swipe-test-area")
            try await AndroidE2E.run(
                "swipe --start-x \(point.x) --start-y \(point.y + 100) --end-x \(point.x) --end-y \(point.y - 100) --duration 0.5",
                environment: AndroidE2E.inputMode(mode)
            )
            _ = try await AndroidE2E.waitForLabel(of: "swipe-count") { $0 == "Count: 1" }
            #expect(try await AndroidE2E.label(of: "last-swipe-direction") == "Direction: Up")
        }
    }

    @Test("touch --down and a later touch --up make one long press across two commands", arguments: AndroidE2E.inputModes)
    func longPressAcrossCommands(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("touch-control", waitingFor: "touch-control-area")
            let point = try await AndroidE2E.centre(of: "touch-control-area")
            try await AndroidE2E.run("touch -x \(point.x) -y \(point.y) --down", environment: AndroidE2E.inputMode(mode))
            try await Task.sleep(for: .milliseconds(1500))
            try await AndroidE2E.run("touch -x \(point.x) -y \(point.y) --up", environment: AndroidE2E.inputMode(mode))
            _ = try await AndroidE2E.waitForLabel(of: "long-press-count") { $0 == "Long presses: 1" }
        }
    }

    @Test("key reaches the focused field", arguments: AndroidE2E.inputModes)
    func key(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("key-press", waitingFor: "key-press-field")
            try await AndroidE2E.run("tap --id key-press-field", environment: AndroidE2E.inputMode(mode))
            try await AndroidE2E.run("key 4", environment: AndroidE2E.inputMode(mode))
            _ = try await AndroidE2E.waitForLabel(of: "last-key-press") { $0 == "Last Key: a (4)" }
        }
    }

    @Test("button back leaves the screen for the menu", arguments: AndroidE2E.inputModes)
    func back(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            try await AndroidE2E.run("button back", environment: AndroidE2E.inputMode(mode))
            _ = try await AndroidE2E.waitForNode { $0["id"] as? String == "menu-title" }
        }
    }

    @Test("ASCII text is typed into the focused field", arguments: AndroidE2E.inputModes)
    func ascii(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
            try await AndroidE2E.run("tap --id text-input-field", environment: AndroidE2E.inputMode(mode))
            try await AndroidE2E.run("type 'hello world'", environment: AndroidE2E.inputMode(mode))
            _ = try await AndroidE2E.waitForFieldValue("hello world")
            #expect(try await AndroidE2E.label(of: "character-count") == "Characters: 11")
        }
    }

    @Test("non-ASCII text is refused on a phone and points to type --replace", arguments: AndroidE2E.inputModes)
    func nonASCIIRefused(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
            try await AndroidE2E.run("tap --id text-input-field", environment: AndroidE2E.inputMode(mode))
            let result = try await AndroidE2E.offsider("type \(AndroidE2E.quote("h\u{E9}llo"))", environment: AndroidE2E.inputMode(mode))
            #expect(result.exitCode == 1, "stderr: \(result.stderr)")
            #expect(result.stderr.contains("is a physical device"))
            #expect(result.stderr.contains("type --replace"))
            #expect(try await AndroidE2E.label(of: "character-count") == nil, "the refused text reached the field")
        }
    }

    @Test("type --replace sets Unicode text whole", arguments: AndroidE2E.inputModes)
    func replaceUnicode(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
            try await AndroidE2E.run("tap --id text-input-field", environment: AndroidE2E.inputMode(mode))
            let text = "h\u{E9}llo 日本 🙂"
            try await AndroidE2E.run("type --replace \(AndroidE2E.quote(text))", environment: AndroidE2E.inputMode(mode))
            let field = try await AndroidE2E.waitForFieldValue(text)
            #expect((field["value"] as? String).map { Array($0.unicodeScalars) } == Array(text.unicodeScalars))
        }
    }
}

@Suite("Android phone screenshot", .serialized, .enabled(if: isAndroidPhoneE2EEnabled))
struct AndroidPhoneScreenshotTests {
    @Test("the PNG decodes at the display's logical pixel size")
    func size() async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            let output = try await AndroidE2E.screenshot("phone.png")
            defer { try? FileManager.default.removeItem(at: output) }
            let size = try AndroidE2E.pngSize(at: output)
            let expected = try await AndroidE2E.logicalPixelSize()
            #expect(size.width == expected.width && size.height == expected.height, "PNG \(size), wm size \(expected)")
        }
    }

    @Test("--mask-secure paints the password field black and leaves it visible without the flag")
    func maskSecure() async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("batch-login-flow", waitingFor: "batch-login-continue")
            try await AndroidE2E.run("tap --id batch-login-continue")
            let field = try await AndroidE2E.waitForNode { $0["id"] as? String == "batch-login-password-field" }
            let centre = try #require(DescribeUITree.centre(of: field))
            let screen = try #require(DescribeUITree.screenSize(in: try await AndroidE2E.tree()))

            let plain = try await AndroidE2E.screenshot("plain.png")
            let masked = try await AndroidE2E.screenshot("masked.png", flags: "--mask-secure")
            defer {
                try? FileManager.default.removeItem(at: plain)
                try? FileManager.default.removeItem(at: masked)
            }
            let size = try AndroidE2E.pngSize(at: masked)
            let scale = Double(size.width) / screen.width
            let x = Int(Double(centre.x) * scale), y = Int(Double(centre.y) * scale)

            #expect(try AndroidE2E.pixel(at: masked, x: x, y: y) == [0, 0, 0])
            #expect(try AndroidE2E.pixel(at: plain, x: x, y: y) != [0, 0, 0], "the field is black without --mask-secure, so the mask proves nothing")
        }
    }

    @Test("raw screencap and the helper produce the same dimensions as the default")
    func capturePathsAgree() async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            var sizes: [String: String] = [:]
            for mode in ["auto", "raw", "helper"] {
                let output = try await AndroidE2E.screenshot("\(mode).png", environment: ["OFFSIDER_ANDROID_CAPTURE": mode])
                defer { try? FileManager.default.removeItem(at: output) }
                let size = try AndroidE2E.pngSize(at: output)
                sizes[mode] = "\(size.width)x\(size.height)"
            }
            #expect(Set(sizes.values).count == 1, "sizes by OFFSIDER_ANDROID_CAPTURE: \(sizes)")
        }
    }
}

@Suite("Android phone helper", .serialized, .enabled(if: isAndroidPhoneE2EEnabled))
struct AndroidPhoneHelperTests {
    @Test("a helper tap leaves no helper running and puts accessibility_enabled back")
    func noHelperLeft() async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            try await AndroidE2E.waitForNoHelper()
            let before = try await AndroidE2E.accessibilityEnabled()

            try await AndroidE2E.run("tap --id tap-test-area", environment: AndroidE2E.inputMode("helper"))

            var processes: [String] = []
            var after = ""
            let clean = try await AndroidE2E.eventually(timeout: 3) {
                processes = try await AndroidE2E.helperProcesses()
                after = try await AndroidE2E.accessibilityEnabled()
                return processes.isEmpty && after == before
            }
            #expect(clean, "helper processes \(processes), accessibility_enabled \(after) (was \(before))")
        }
    }

    @Test("doctor on the phone exits 0 or 3")
    func doctor() async throws {
        let result = try await AndroidE2E.offsider("doctor")
        #expect([0, 3].contains(result.exitCode), "doctor exited \(result.exitCode): \(result.stdout)\(result.stderr)")
    }
}

@Suite("Android phone timing", .serialized, .enabled(if: isAndroidPhoneE2EEnabled))
struct AndroidPhoneTimingTests {
    @Test("ten tap --id runs per input mode have a median inside 5 s, and only the helper mode injects through the helper", arguments: AndroidE2E.inputModes)
    func tapByID(mode: String) async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            var environment = AndroidE2E.inputMode(mode)
            environment["OFFSIDER_TIMINGS"] = "1"
            var times: [Int] = []
            var phases: Set<String> = []
            for _ in 0..<10 {
                let started = Date()
                let result = try await AndroidE2E.run("tap --id tap-test-area", environment: environment)
                times.append(Int((Date().timeIntervalSince(started) * 1000).rounded()))
                phases.formUnion(AndroidE2E.timingPhases(result.stderr))
            }
            let sorted = times.sorted()
            let median = (sorted[4] + sorted[5]) / 2
            print("phone tap --id (\(mode)) times (ms): \(times.map(String.init).joined(separator: ", ")); median \(median) ms")

            #expect(median < 5000, "median \(median) ms over \(times)")
            #expect(phases.contains("helper-inject") == (mode == "helper"), "phases under \(mode): \(phases.sorted())")
        }
    }
}
