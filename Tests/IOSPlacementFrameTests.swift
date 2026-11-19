import Foundation
import FBControlCore
import OffsiderCore
import Testing
@testable import Offsider

@Suite("iOS placement frame")
@MainActor
struct IOSPlacementFrameTests {
    private final class Reads {
        var frameReads = 0
        var fullReads = 0
        var noted: [UITree] = []
    }

    private static let portrait = UIFrame(x: 0, y: 0, width: 402, height: 874)
    private static let letterboxed = UIFrame(x: 0, y: 0, width: 874, height: 402)

    private static func tree(_ frame: UIFrame) -> UITree {
        UITree(platform: .ios, device: "00000000-0000-0000-0000-000000000001", roots: [
            UINode(role: .application, label: "Playground", frame: frame, native: .ios(IOSNativeAttributes(pid: 4242)), children: [UINode(role: .button, label: "Next Page", frame: UIFrame(x: 145, y: 432, width: 113, height: 44), native: .ios(IOSNativeAttributes(pid: 4242)))])
        ])
    }

    private func place(guardHasRules: Bool, frameRead: UIFrame?, fullRead: UIFrame) async throws -> (frame: UIFrame?, reads: Reads) {
        let reads = Reads()
        let frame = try await IOSBackend.placementFrame(
            guardHasRules: guardHasRules,
            frameRead: { reads.frameReads += 1; return frameRead },
            fullRead: { reads.fullReads += 1; return Self.tree(fullRead) },
            note: { reads.noted.append($0) },
            wait: { _ in }
        )
        return (frame, reads)
    }

    @Test("with no guard rules a coordinate is placed on the frame read alone")
    func frameReadAlone() async throws {
        let (frame, reads) = try await place(guardHasRules: false, frameRead: Self.portrait, fullRead: Self.letterboxed)
        #expect(frame == Self.portrait)
        #expect(reads.frameReads == 1)
        #expect(reads.fullReads == 0)
    }

    @Test("with guard rules the guard is handed a whole tree read for this input, and no frame read stands in for it")
    func guardRulesGetWholeTree() async throws {
        let (frame, reads) = try await place(guardHasRules: true, frameRead: Self.portrait, fullRead: Self.letterboxed)
        #expect(frame == Self.letterboxed)
        #expect(reads.frameReads == 0)
        #expect(reads.fullReads == 1)
        #expect(reads.noted.count == 1)
        #expect(reads.noted.first?.roots.first?.children.first?.label == "Next Page")
    }

    @Test("a root that never gets a frame is read a bounded number of times, then the whole read places the point")
    func emptyRootFallsBack() async throws {
        for answer in [UIFrame(x: 0, y: 0, width: 0, height: 0), nil] as [UIFrame?] {
            let (frame, reads) = try await place(guardHasRules: false, frameRead: answer, fullRead: Self.letterboxed)
            #expect(frame == Self.letterboxed)
            #expect(reads.frameReads == IOSBackend.frameReadAttempts)
            #expect(reads.fullReads == 1)
        }
    }

    @Test("an app that has just opened answers with an empty root first, and the next frame read places the point")
    func emptyRootThenFrame() async throws {
        var answers: [UIFrame?] = [UIFrame(x: 0, y: 0, width: 0, height: 0), Self.letterboxed]
        var waits: [Duration] = []
        let frame = try await IOSBackend.placementFrame(
            guardHasRules: false,
            frameRead: { answers.removeFirst() },
            fullRead: { Issue.record("no whole read expected"); return Self.tree(Self.portrait) },
            note: { _ in },
            wait: { waits.append($0) }
        )
        #expect(frame == Self.letterboxed)
        #expect(waits == [.milliseconds(50)])
    }

    @Test("every coordinate reads the frame again, so a turn or another app in front between inputs is seen")
    func everyInputReadsAgain() async throws {
        var answers = [Self.portrait, Self.letterboxed]
        var frames: [UIFrame?] = []
        for _ in 0..<2 {
            frames.append(try await IOSBackend.placementFrame(
                guardHasRules: false,
                frameRead: { answers.removeFirst() },
                fullRead: { Issue.record("no whole read expected"); return Self.tree(Self.portrait) },
                note: { _ in },
                wait: { _ in }
            ))
        }
        #expect(frames == [Self.portrait, Self.letterboxed])
    }

    @Test("the frame read asks for what names the root as the app, its frame and its process")
    func frameKeysCarryTheApplicationFrame() throws {
        let keys = Set(AccessibilityFetcher.frameKeys.map(\.rawValue))
        let full: [String: Any] = [
            "type": "Application", "role": "AXApplication", "subrole": NSNull(), "role_description": "application", "pid": 4242,
            "frame": ["x": 0, "y": 0, "width": 874, "height": 402], "AXLabel": "Playground", "AXUniqueId": "root", "AXValue": "x",
            "children": [],
        ]
        let trimmed = full.filter { keys.contains($0.key) || $0.key == "children" }
        let data = try JSONSerialization.data(withJSONObject: [trimmed])
        let roots = try IOSAccessibilityMapping.roots(fromJSON: data)
        #expect(UITree.applicationFrame(in: roots) == Self.letterboxed)
        #expect(roots.first?.iosPID == 4242)
        #expect(!keys.contains(FBAXKeys.label.rawValue))
    }
}
