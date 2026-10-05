import Foundation
import OffsiderCore
import OffsiderIOSDevice

extension IOSDeviceBackend {
    /// Debug and info go to the Offsider logger; warnings print one `Warning:` line on stderr.
    static func make(logger: OffsiderLogger) -> IOSDeviceBackend {
        let sink = IOSDeviceLogSink(logger: logger)
        var host = IOSDeviceHost.live()
        host.runnerSource = Bundle.module.url(forResource: "runner", withExtension: nil)
        host.sessionExecutable = Bundle.main.executableURL
        if Timings.isEnabled {
            host.timing = .printing { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        }
        return IOSDeviceBackend(host: host) { level, message in sink.write(level, message) }
    }
}

/// `OffsiderLogger` is an idb logger class, not `Sendable`; this box is the one place iOS device log lines cross into it.
private final class IOSDeviceLogSink: @unchecked Sendable {
    private let logger: OffsiderLogger

    init(logger: OffsiderLogger) {
        self.logger = logger
    }

    func write(_ level: IOSDeviceLogLevel, _ message: String) {
        switch level {
        case .debug:
            logger.debug().log(message)
        case .info:
            logger.info().log(message)
        case .notice:
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        case .warning:
            FileHandle.standardError.write(Data("Warning: \(message)\n".utf8))
        }
    }
}

extension IOSDeviceError: UserFacingError {
    var userFacingDescription: String { message }
}
