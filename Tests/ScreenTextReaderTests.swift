import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Screen text reads")
struct ScreenTextReaderTests {
    @Test("twice as many text reads at once as the Mac has cores all finish and read the text, so a parallel run cannot stall on them")
    func readsAtOnceAllFinish() async {
        await #expect(processExitsWith: .success) { @MainActor in
            Thread.detachNewThread { Thread.sleep(forTimeInterval: 30); _exit(2) }
            guard let png = try? OwnCoverTests.screenshot(showing: "Send") else { exit(3) }
            let region = OwnCoverTests.send, viewport = FakeUI.frame(0, 0, OwnCoverTests.width, OwnCoverTests.height)
            let reads = ProcessInfo.processInfo.activeProcessorCount * 2
            let shown = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<reads {
                    group.addTask { ShownText.shows(label: "Send", in: await ScreenTextReader.lines(in: png, region: region, viewport: viewport)) }
                }
                return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
            exit(shown == reads ? 0 : 4)
        }
    }
}
