import Darwin
import Foundation

public struct ProcessCaptureResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct ProcessCaptureTimeoutError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let command: String
    public let timeout: TimeInterval

    public init(command: String, timeout: TimeInterval) {
        self.command = command
        self.timeout = timeout
    }

    public var errorDescription: String? { userFacingDescription }
    public var description: String { userFacingDescription }
    public var userFacingDescription: String {
        "\(command) timed out after \(Int(timeout)) s"
    }
}

/// Runs a short-lived tool with a hard timeout and captures both output streams.
public enum ProcessCapture {
    /// A nil `environment` inherits this process's environment.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessCaptureResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
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
