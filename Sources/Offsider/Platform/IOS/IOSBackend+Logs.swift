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
            if case .live(let duration) = query.window {
                try await Self.runLive(operation, for: duration)
            } else {
                try await operation.waitUntilCompleted()
            }
        } catch {
            continuation.finish()
            await reader.value
            throw CLIError(errorDescription: "Failed to read logs from simulator \(id.rawValue): \(error.localizedDescription)")
        }
        await Self.drain(consumer)
        continuation.finish()
        await reader.value
    }

    /// Waits for `duration` or cancellation, then stops the stream; `log stream` exits on SIGTERM with a non-zero status.
    private static func runLive(_ operation: any AsyncLogOperation, for duration: Duration?) async throws {
        let box = OperationBox(operation)
        let waiter = Task { try await box.operation.waitUntilCompleted() }
        let end = duration.map { ContinuousClock.now + $0 }
        while !Task.isCancelled {
            if let end, ContinuousClock.now >= end { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        waiter.cancel()
        _ = await waiter.result
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
            throw CLIError(errorDescription: "App \(bundleID) is not installed on simulator \(simulator.udid). Install it, or drop --app to read all logs.")
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

private final class OperationBox: @unchecked Sendable {
    let operation: any AsyncLogOperation
    init(_ operation: any AsyncLogOperation) { self.operation = operation }
}

private final class FutureBox: @unchecked Sendable {
    let future: FBFuture<NSNull>
    init(_ future: FBFuture<NSNull>) { self.future = future }
}
