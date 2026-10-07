import Darwin
import Foundation

/// Reads only what xcodebuild appended to `runner.log` since the last check, for failures it waits on instead of exiting.
struct RunnerLogWatch {
    enum Finding: Equatable {
        /// Device preparation is waiting for the device to be unlocked.
        case deviceLocked
        /// XCTest gave up enabling UI automation, as when the device's "Enter Passcode for XCTest" prompt goes unanswered.
        case automationNotEnabled
    }

    static let chunkLimit = 64 * 1024
    /// The unfinished last line kept for the next check, so a match split across two writes is still seen.
    static let carryLimit = 4 * 1024

    let path: String
    private(set) var offset: off_t = 0
    private var carry = Data()

    init(path: String) {
        self.path = path
    }

    /// The first finding in at most `maxBytes` appended since the last check.
    mutating func check(maxBytes: Int = chunkLimit) -> Finding? {
        let appended = readAppended(maxBytes: maxBytes)
        guard !appended.isEmpty else { return nil }
        let window = carry + appended
        let lastBreak = window.lastIndex(of: UInt8(ascii: "\n")).map { window.index(after: $0) } ?? window.startIndex
        carry = Data(window[lastBreak...].suffix(Self.carryLimit))
        for line in window.split(separator: UInt8(ascii: "\n")) {
            if let finding = Self.finding(in: String(decoding: line, as: UTF8.self)) { return finding }
        }
        return nil
    }

    /// The device-preparation unlock error, or XCTest's automation timeout, whatever the device is called.
    static func finding(in line: String) -> Finding? {
        if line.range(of: "enabling automation mode", options: .caseInsensitive) != nil { return .automationNotEnabled }
        guard line.contains("com.apple.dt.deviceprep") else { return nil }
        let asksToUnlock = line.range(of: "unlock", options: .caseInsensitive) != nil || line.range(of: "locked", options: .caseInsensitive) != nil
        return asksToUnlock ? .deviceLocked : nil
    }

    private mutating func readAppended(maxBytes: Int) -> Data {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return Data() }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return Data() }
        if info.st_size < offset {
            offset = 0
            carry = Data()
        }
        let count = Int(min(info.st_size - offset, off_t(maxBytes)))
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, offset) }
        guard read > 0 else { return Data() }
        offset += off_t(read)
        return data.prefix(read)
    }
}
