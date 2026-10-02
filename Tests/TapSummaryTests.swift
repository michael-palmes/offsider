import Testing
@testable import Offsider

@Suite("Tap summaries")
struct TapSummaryTests {
    @Test("a selector tap names the selector and the point it tapped")
    func selector() {
        #expect(Tap.completionLine(selector: "id=BackButton", at: (x: 22.1, y: 76.2)) == "✓ Tap on id=BackButton at (22.1, 76.2) completed successfully")
        #expect(Tap.completionLine(selector: "label=Settings", at: (x: 217.149, y: 272.2)) == "✓ Tap on label=Settings at (217.15, 272.2) completed successfully")
    }

    @Test("a coordinate tap keeps its plain wording")
    func coordinates() {
        #expect(Tap.completionLine(selector: nil, at: (x: 200, y: 400)) == "✓ Tap at (200, 400) completed successfully")
    }
}
