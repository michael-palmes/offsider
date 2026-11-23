import FBSimulatorControl
import Foundation
import IOSurface
import OffsiderCore

/// A simulator's main screen read in place from idb's framebuffer surface, a region at a time, with no capture or encoding.
@MainActor
final class SurfacePixels: TargetPixels {
    private let framebuffer: FBFramebuffer
    private let holder: FramebufferSurfaceHolder
    private let pointWidth: Double

    private init(framebuffer: FBFramebuffer, holder: FramebufferSurfaceHolder, pointWidth: Double) {
        self.framebuffer = framebuffer
        self.holder = holder
        self.pointWidth = pointWidth
    }

    static func attach(to framebuffer: FBFramebuffer, pointWidth: Double) -> SurfacePixels? {
        let holder = FramebufferSurfaceHolder()
        guard let surface = framebuffer.attach(holder, on: holder.queue) else {
            framebuffer.detach(holder)
            return nil
        }
        holder.didChange(surface)
        return SurfacePixels(framebuffer: framebuffer, holder: holder, pointWidth: pointWidth)
    }

    func fingerprint(of frame: UIFrame) -> ImageFingerprint? {
        guard let surface = holder.surface, surface.bytesPerElement == 4, pointWidth > 0 else { return nil }
        let scale = Double(surface.width) / pointWidth
        let left = max(0, Int((frame.x * scale).rounded(.down))), top = max(0, Int((frame.y * scale).rounded(.down)))
        let right = min(surface.width, Int(((frame.x + frame.width) * scale).rounded(.up)))
        let bottom = min(surface.height, Int(((frame.y + frame.height) * scale).rounded(.up)))
        guard right > left, bottom > top else { return nil }
        guard surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return nil }
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytesPerRow = surface.bytesPerRow
        let start = surface.baseAddress.advanced(by: top * bytesPerRow + left * 4)
        let region = UnsafeRawBufferPointer(start: start, count: (bottom - top - 1) * bytesPerRow + (right - left) * 4)
        return ImageFingerprint(rgba: region, width: right - left, height: bottom - top, bytesPerRow: bytesPerRow, columns: 4, rows: 4)
    }

    func close() {
        framebuffer.detach(holder)
        holder.didChange(nil)
    }
}

final class FramebufferSurfaceHolder: NSObject, FBFramebufferConsumer, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.mpalmes.offsider.surface-pixels")
    private let lock = NSLock()
    private var current: IOSurface?

    var surface: IOSurface? {
        lock.withLock { current }
    }

    func didChange(_ surface: IOSurface?) {
        lock.withLock {
            current?.decrementUseCount()
            surface?.incrementUseCount()
            current = surface
        }
    }

    func didReceiveDamageRect() {}
}

extension IOSBackend: TargetPixelReading {
    /// Portrait main screens only: the surface keeps the display's native orientation, and a foldable's other display is not on it.
    func targetPixels(for id: DeviceID) async -> (any TargetPixels)? {
        guard let simulator = try? await simulator(for: id), !displayCatalog.isFoldable(simulator),
              let screen = try? await screenInfo(for: id), screen.rotation == nil || screen.rotation == .portrait,
              let framebuffer = try? await Timings.measure("framebuffer", { try await bridgeFBFuture(simulator.connectToFramebuffer()) }) else {
            return nil
        }
        return SurfacePixels.attach(to: framebuffer, pointWidth: screen.width)
    }
}
