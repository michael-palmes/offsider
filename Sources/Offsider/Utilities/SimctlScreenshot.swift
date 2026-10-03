import Foundation
import OffsiderCore

/// `xcrun simctl io <udid> screenshot`, which can pick a display where idb's framebuffer cannot.
enum SimctlScreenshot {
    /// `display` is a simulator screen ID or device name; nil lets simctl choose.
    static func arguments(udid: String, display: String?, output: String) -> [String] {
        ["simctl", "io", udid, "screenshot", "--type", "png"] + (display.map { ["--display=\($0)"] } ?? []) + [output]
    }

    static func capturePNG(udid: String, display: String?, timeout: TimeInterval = 30, logger: OffsiderLogger) async throws -> Data {
        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        let target = display.map { "display \($0) of simulator \(udid)" } ?? "simulator \(udid)"
        let result: ProcessCaptureResult
        do {
            result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: arguments(udid: udid, display: display, output: output.path), timeout: timeout)
        } catch {
            throw CLIError(errorDescription: "Offsider could not capture \(target): \(error.localizedDescription). Check it is booted with `offsider list-devices`.")
        }
        guard result.status == 0, let data = FileManager.default.contents(atPath: output.path), !data.isEmpty else {
            let detail = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "simctl exited with \(result.status)"
            logger.info().log("simctl screenshot failed: \(result.stderr)")
            throw CLIError(errorDescription: "Offsider could not capture \(target): \(detail). Check it is booted with `offsider list-devices`.")
        }
        return data
    }

    /// The pixel size of the default display's screenshot; nil when simctl fails or writes no PNG.
    static func pixelDimensions(udid: String, logger: OffsiderLogger) async -> (width: Int, height: Int)? {
        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            let result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: arguments(udid: udid, display: nil, output: output.path), timeout: 3)
            guard result.status == 0 else {
                logger.info().log("Screenshot probe: simctl screenshot failed: \(result.stderr)")
                return nil
            }
        } catch {
            logger.info().log("Screenshot probe: \(error.localizedDescription)")
            return nil
        }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: output)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 24) ?? Data()
        } catch {
            logger.info().log("Screenshot probe: could not read temp PNG: \(error)")
            return nil
        }
        guard let size = pngDimensions(header) else {
            logger.info().log("Screenshot probe: output is not a valid PNG")
            return nil
        }
        logger.info().log("Screenshot probe: \(size.width)×\(size.height)px")
        return size
    }

    /// Width and height from a PNG's signature and IHDR chunk, the first 24 bytes.
    static func pngDimensions(_ header: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](header.prefix(24))
        guard bytes.count == 24, bytes.prefix(8).elementsEqual(signature) else { return nil }
        let width = bytes[16..<20].reduce(0) { Int($0) << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { Int($0) << 8 | Int($1) }
        return (width, height)
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("offsider-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")
    }
}
