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

    private static func read(_ png: Data, region: UIFrame, viewport: UIFrame) -> [String] {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), viewport.width > 0, viewport.height > 0,
              abs(Double(image.width) / Double(image.height) - viewport.width / viewport.height) < 0.02,
              let shown = region.intersection(viewport) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.regionOfInterest = CGRect(
            x: (shown.x - viewport.x) / viewport.width,
            y: 1 - (shown.y - viewport.y + shown.height) / viewport.height,
            width: shown.width / viewport.width,
            height: shown.height / viewport.height
        )
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
