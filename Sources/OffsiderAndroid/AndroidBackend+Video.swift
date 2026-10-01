import CoreGraphics
import Darwin
import Foundation
import OffsiderCore

extension AndroidBackend: FrameCapturing {
    /// A raw RGBA frame the emulator scales itself; over adb, `screencap` scaled on the Mac.
    public func captureFrame(for id: DeviceID, scale: Double) async throws -> CGImage {
        try await prepare()
        let serial = id.rawValue
        do {
            guard case .grpc(let emulator) = try await transport(for: serial) else {
                return try AndroidScreenCapture.scaled(try AndroidScreenCapture.decodePNG(try await adbScreenshot(serial)), by: scale)
            }
            let geometry = try await geometry(for: serial)
            let frame = try await emulator.screenshot(.rgba8888, fitting: Self.frameBox(for: geometry, scale: scale))
            return try AndroidScreenCapture.image(from: frame, guestRotation: geometry.rotation)
        } catch let failure as AndroidScreenCapture.ImageFailure {
            throw AndroidError.screenshotFailed(serial, detail: failure.detail)
        }
    }

    /// A square box on the long side, so the emulator fits the frame whichever way it is turned.
    static func frameBox(for geometry: AndroidDisplayGeometry, scale: Double) -> FrameBox? {
        guard scale < 1 else { return nil }
        let side = max(1, Int((Double(max(geometry.naturalWidth, geometry.naturalHeight)) * scale).rounded()))
        return FrameBox(width: side, height: side)
    }
}

extension AndroidBackend: RawVideoStreaming {
    /// `streamScreenshot` as RGBA, turned upright and swapped to BGRA, at most `fps` frames a second; gRPC only.
    public func streamBGRA(
        from id: DeviceID,
        fps: Int,
        quality: Int,
        scale: Double,
        to fileDescriptor: Int32,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws {
        try await prepare()
        let serial = id.rawValue
        let transport = try await transport(for: serial)
        guard case .grpc(let emulator) = transport else {
            let reason: AdbReason
            if case .adb(let why) = transport { reason = why } else { reason = .forced }
            throw AndroidError.grpcRequired(
                feature: "Streaming BGRA frames",
                serial: serial,
                avd: await avdName(for: serial),
                reason: reason,
                alternative: "use --format mjpeg"
            )
        }
        let geometry = try await geometry(for: serial)
        let frames = emulator.screenshotStream(.rgba8888, fitting: Self.frameBox(for: geometry, scale: scale))
        let interval = Duration.seconds(1.0 / Double(max(1, fps)))
        let log = self.log

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var next = ContinuousClock.now
                var announced = false
                for try await frame in frames {
                    guard ContinuousClock.now >= next else { continue }
                    next = ContinuousClock.now + interval
                    let pixels: AndroidScreenCapture.Pixels
                    do {
                        pixels = try AndroidScreenCapture.bgra(from: frame, guestRotation: geometry.rotation)
                    } catch let failure as AndroidScreenCapture.ImageFailure {
                        throw AndroidError.screenshotFailed(serial, detail: failure.detail)
                    }
                    if !announced {
                        announced = true
                        log(.info, "BGRA frames from \(serial) are \(pixels.width) x \(pixels.height)")
                    }
                    try Self.write(pixels.bytes, to: fileDescriptor)
                }
            }
            group.addTask {
                while !(await isCancelled()) {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    nonisolated static func write(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fileDescriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AndroidError.videoOutputFailed(detail: String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }
}
