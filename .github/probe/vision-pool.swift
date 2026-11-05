import AppKit
import Vision

// Temporary: shows whether Vision text reads deadlock Swift's thread pool on this runner. Removed before merge.
func picture() -> CGImage {
    let context = CGContext(data: nil, width: 800, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 1600))
    let text = NSAttributedString(string: "Send", attributes: [.font: NSFont.systemFont(ofSize: 68, weight: .semibold), .foregroundColor: NSColor.black])
    context.textPosition = CGPoint(x: 272, y: 112)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    return context.makeImage()!
}

func read(_ image: CGImage) -> Bool {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).contains { $0.topCandidates(1).first?.string == "Send" }
}

@main
struct Probe {
    static func main() async {
        let mode = CommandLine.arguments[1], reads = Int(CommandLine.arguments[2])!
        if mode == "width" {
            let started = Date()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<reads { group.addTask(priority: .userInitiated) { Thread.sleep(forTimeInterval: 0.5) } }
            }
            print("pool width: about \(Int((Double(reads) * 0.5 / Date().timeIntervalSince(started)).rounded())) user-initiated threads")
            return
        }
        let image = picture()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 30)
            print("\(mode), \(reads) at once: stuck after 30 s")
            fflush(stdout)
            _exit(2)
        }
        let started = Date()
        let found = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<reads {
                group.addTask {
                    if mode == "detached" { return await Task.detached(priority: .userInitiated) { read(image) }.value }
                    return await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: read(image)) }
                    }
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        print("\(mode), \(reads) at once: \(found) read the text in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    }
}
