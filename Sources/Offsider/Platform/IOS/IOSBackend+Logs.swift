import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import OffsiderCore

extension IOSBackend: LogReading {
    /// The simulator's own `log show` for history or `log stream` for live output, as ndjson, with info and debug messages.
    func readLogs(_ query: LogQuery, on id: DeviceID, onEntry: @escaping @MainActor (LogEntry) -> Void) async throws {
        let simulator = try await logSimulator(for: id)
        var executable: String?
        if case .app(let bundleID) = query.source {
            executable = try await Self.executableName(of: bundleID, on: simulator)
        }
        let predicate = LogText.iosPredicate(for: query.source, executable: executable, extra: query.predicate)
        let arguments = LogText.iosLogArguments(window: query.window, predicate: predicate)
        let cutoff = query.window.cutoff(now: Date())
        logger.info().log("Reading logs: log \(arguments.joined(separator: " "))")

        let (lines, continuation) = AsyncStream<String>.makeStream()
        let consumer = FBBlockDataConsumer.asynchronousLineConsumer { line in
            continuation.yield(line)
        }
        let reader = Task { @MainActor in
            for await line in lines {
                guard let entry = LogText.parseIOSNDJSON(line) else { continue }
                if let cutoff, let timestamp = entry.timestamp, timestamp < cutoff { continue }
                onEntry(entry)
            }
        }

        do {
            let operation = try await simulator.tailLog(arguments: arguments, consumer: consumer)
            let box = OperationBox(operation)
            let exitStatus: @Sendable () async -> Int32? = {
                guard let process = (box.operation as? FBProcessLogOperation)?.process else { return nil }
                return try? await awaitExitCode(of: process)
            }
            if case .live(let duration) = query.window {
                try await LiveLogStream.run(
                    for: duration,
                    predicate: query.predicate,
                    wait: { try await box.operation.waitUntilCompleted() },
                    exitStatus: exitStatus
                )
            } else {
                do {
                    try await operation.waitUntilCompleted()
                } catch {
                    throw await LiveLogStream.failure(error, status: exitStatus(), predicate: query.predicate)
                }
            }
        } catch {
            continuation.finish()
            await reader.value
            if let error = error as? CLIError { throw error }
            throw CLIError(errorDescription: "Failed to read logs from simulator \(id.rawValue): \(error.localizedDescription)", reason: .logStreamFailed)
        }
        await Self.drain(consumer)
        continuation.finish()
        await reader.value
    }

    /// Lets the consumer hand over lines it already read; gives up after two seconds.
    private static func drain(_ consumer: any FBDataConsumerLifecycle) async {
        let box = FutureBox(consumer.finishedConsuming)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await bridgeFBFuture(box.future) }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The installed app's executable name, which is the process name `log` filters on.
    private static func executableName(of bundleID: String, on simulator: FBSimulator) async throws -> String {
        let application: FBInstalledApplication
        do {
            application = try await simulator.installedApplication(bundleID: bundleID)
        } catch {
            throw CLIError(errorDescription: "App \(bundleID) is not installed on simulator \(simulator.udid). Install it, or drop --app to read all logs.", reason: .appNotInstalled)
        }
        if let path = application.bundle.binary?.path {
            return (path as NSString).lastPathComponent
        }
        return application.bundle.name
    }

    private func logSimulator(for id: DeviceID) async throws -> FBSimulator {
        guard let simulator = try await cachedSimulator(udid: id.rawValue, logger: logger) else {
            throw CLIError.deviceNotFound(id: id.rawValue)
        }
        return simulator
    }
}

/// Runs `log stream` for a window, ending early and failing when the stream itself exits.
enum LiveLogStream {
    /// Waits for `duration`, cancellation or the stream's end, then stops it; `log stream` exits on SIGTERM with a non-zero status.
    @MainActor
    static func run(
        for duration: Duration?,
        predicate: String?,
        clock: PollClock = .live,
        wait: @escaping @Sendable () async throws -> Void,
        exitStatus: @escaping @Sendable () async -> Int32?
    ) async throws {
        let ended = Outcome()
        let waiter = Task { @MainActor in
            do {
                try await wait()
                ended.result = .success(())
            } catch {
                ended.result = .failure(error)
            }
        }
        let end = duration.map { clock.now() + Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        while !Task.isCancelled, ended.result == nil {
            if let end, clock.now() >= end { break }
            try? await clock.sleep(.milliseconds(100))
            await Task.yield()
        }
        guard let outcome = ended.result else {
            waiter.cancel()
            await waiter.value
            return
        }
        if case .failure(let error) = outcome {
            throw failure(error, status: await exitStatus(), predicate: predicate)
        }
    }

    @MainActor
    private final class Outcome {
        var result: Result<Void, any Error>?
    }

    /// The error for a `log` process that failed on its own, pointing at `--predicate` when one was given.
    static func failure(_ error: any Error, status: Int32?, predicate: String?) -> CLIError {
        let hint = predicate == nil ? "" : " Check the --predicate syntax."
        guard let status else {
            return CLIError(errorDescription: "The simulator's log command stopped: \(error.localizedDescription).\(hint)", reason: .logStreamFailed)
        }
        return CLIError(errorDescription: "The simulator's log command exited with status \(status).\(hint)", reason: .logStreamFailed)
    }
}

private final class OperationBox: @unchecked Sendable {
    let operation: any AsyncLogOperation
    init(_ operation: any AsyncLogOperation) { self.operation = operation }
}

private final class FutureBox: @unchecked Sendable {
    let future: FBFuture<NSNull>
    init(_ future: FBFuture<NSNull>) { self.future = future }
}
