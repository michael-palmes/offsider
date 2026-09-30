import Foundation
import OffsiderAndroid
import OffsiderCore

extension AndroidBackend {
    /// Debug and info go to the Offsider logger; warnings print one `Warning:` line on stderr.
    static func make(logger: OffsiderLogger, host: AndroidHost = .live()) -> AndroidBackend {
        AndroidBackend(host: host, log: logBridge(logger: logger))
    }

    static func logBridge(logger: OffsiderLogger) -> AndroidLog {
        let sink = AndroidLogSink(logger: logger)
        return { level, message in sink.write(level, message) }
    }
}

/// `OffsiderLogger` is an idb logger class, not `Sendable`; this box is the one place Android log lines cross into it.
private final class AndroidLogSink: @unchecked Sendable {
    private let logger: OffsiderLogger

    init(logger: OffsiderLogger) {
        self.logger = logger
    }

    func write(_ level: AndroidLogLevel, _ message: String) {
        switch level {
        case .debug:
            logger.debug().log(message)
        case .info:
            logger.info().log(message)
        case .warning:
            FileHandle.standardError.write(Data("Warning: \(message)\n".utf8))
        }
    }
}

extension AndroidError: UserFacingError {
    var userFacingDescription: String { message }
}

extension PlatformUnavailable: UserFacingError {
    var userFacingDescription: String { message }
}
