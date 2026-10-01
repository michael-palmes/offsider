import Foundation
import Testing

@Suite("Android video", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidVideoTests {
    /// Starts offsider against the guarded device, with stdout and stderr collected as they arrive.
    private final class Running: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        init(_ arguments: [String]) throws {
            process.executableURL = URL(fileURLWithPath: try TestHelpers.getOffsiderPath())
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                self?.lock.withLock { self?.out.append(chunk) }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                self?.lock.withLock { self?.err.append(chunk) }
            }
            try process.run()
        }

        var stdoutCount: Int { lock.withLock { out.count } }
        var stderrText: String { lock.withLock { String(decoding: err, as: UTF8.self) } }

        func interruptAndWait(timeout: TimeInterval = 30) async throws -> Int32 {
            if process.isRunning { process.interrupt() }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    @Test("record-video writes an MP4 and names the source a device")
    func record() async throws {
        let serial = try await AndroidE2E.serial()
        let output = AndroidE2E.temporaryFile("video.mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let running = try Running(["record-video", "--output", output.path, "--device", serial])
        try await Task.sleep(for: .seconds(3))
        let status = try await running.interruptAndWait()

        #expect(status == 0, "stderr: \(running.stderrText)")
        #expect(running.stderrText.contains("Recording device \(serial)"))
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        #expect(size > 10_000)
    }

    @Test("stream-video --format bgra sends a full frame of width x height x 4 bytes")
    func bgraFrame() async throws {
        let serial = try await AndroidE2E.serial()
        let size = try await AndroidE2E.logicalPixelSize()
        let frameBytes = size.width * size.height * 4
        let running = try Running(["stream-video", "--format", "bgra", "--device", serial])
        let deadline = Date().addingTimeInterval(20)
        while running.stdoutCount < frameBytes, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let received = running.stdoutCount
        _ = try await running.interruptAndWait()

        #expect(received >= frameBytes, "received \(received) of \(frameBytes) bytes")
        #expect(running.stderrText.contains("sends a new frame only when the screen changes"))
    }
}
