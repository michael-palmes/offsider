import CoreGraphics
import Foundation
import ImageIO
import OffsiderCore
import Vision

/// Reads text off a screenshot with macOS's on-device recognition; nothing leaves the Mac.
enum ScreenTextReader {
    /// The lines recognised inside `region`, in the coordinates of `viewport`; empty when the image cannot be read or does not fit the screen.
    static func lines(in png: Data, region: UIFrame, viewport: UIFrame) async -> [String] {
        // Vision's perform blocks until work it queues on Swift's thread pool finishes, so it must not hold a pool thread itself.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: read(png, region: region, viewport: viewport)) }
        }
    }

    /// The lines recognised inside `region` of a capture, framed in points; nil when recognition failed.
    static func framedLines(in image: CGImage, region: UIFrame, pixelsPerPoint: Double) async -> [ScreenTextLine]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: framedRead(image, region: region, pixelsPerPoint: pixelsPerPoint))
            }
        }
    }

    private static func framedRead(_ image: CGImage, region: UIFrame, pixelsPerPoint: Double) -> [ScreenTextLine]? {
        let pixels = CGRect(x: region.x * pixelsPerPoint, y: region.y * pixelsPerPoint, width: region.width * pixelsPerPoint, height: region.height * pixelsPerPoint)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelsPerPoint > 0, !pixels.isEmpty, let cropped = image.cropping(to: pixels) else { return nil }
        let request = fastRequest()
        guard (try? VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])) != nil else { return nil }
        let width = pixels.width / pixelsPerPoint, height = pixels.height / pixelsPerPoint
        let left = pixels.minX / pixelsPerPoint, top = pixels.minY / pixelsPerPoint
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            let frame = UIFrame(x: left + box.minX * width, y: top + (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
            return ScreenTextLine(text: text, frame: frame)
        }
    }

    private static func read(_ png: Data, region: UIFrame, viewport: UIFrame) -> [String] {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), viewport.width > 0, viewport.height > 0,
              abs(Double(image.width) / Double(image.height) - viewport.width / viewport.height) < 0.02,
              let shown = region.intersection(viewport) else { return [] }
        let request = fastRequest()
        request.regionOfInterest = CGRect(
            x: (shown.x - viewport.x) / viewport.width,
            y: 1 - (shown.y - viewport.y + shown.height) / viewport.height,
            width: shown.width / viewport.width,
            height: shown.height / viewport.height
        )
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private static func fastRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        return request
    }
}
