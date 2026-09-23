import Darwin
import Foundation

struct ProcessCaptureResult: Equatable, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct ProcessCaptureTimeoutError: LocalizedError, UserFacingError {
    let command: String
    let timeout: TimeInterval

    var errorDescription: String? { userFacingDescription }
    var userFacingDescription: String {
        "\(command) timed out after \(Int(timeout)) s"
    }
}

/// Runs a short-lived tool with a hard timeout and captures both output streams.
enum ProcessCapture {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessCaptureResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutBuffer = CaptureBuffer(stdoutPipe.fileHandleForReading)
        let stderrBuffer = CaptureBuffer(stderrPipe.fileHandleForReading)
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                terminate(process)
                throw error
            }
        }
        if process.isRunning {
            terminate(process)
            stdoutBuffer.close()
            stderrBuffer.close()
            let name = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(2)).joined(separator: " ")
            throw ProcessCaptureTimeoutError(command: name, timeout: timeout)
        }
        // Skip waitUntilExit (it can hang on a cooperative thread) and stop reading soon, as a grandchild can hold the pipe.
        let drainDeadline = Date().addingTimeInterval(1)
        while !(stdoutBuffer.isFinished && stderrBuffer.isFinished), Date() < drainDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        stdoutBuffer.close()
        stderrBuffer.close()
        return ProcessCaptureResult(
            status: process.terminationStatus,
            stdout: stdoutBuffer.text,
            stderr: stderrBuffer.text
        )
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var data = Data()
    private var finished = false

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.append(chunk)
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if chunk.isEmpty {
            finished = true
            handle.readabilityHandler = nil
        } else {
            data.append(chunk)
        }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        handle.readabilityHandler = nil
        finished = true
    }
}
