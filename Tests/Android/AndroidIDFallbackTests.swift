import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("--id fallback for native Android ids")
struct AndroidIDFallbackTests {
    private static func button(_ id: String, x: Double) -> UINode {
        UINode(role: .button, id: id, frame: UIFrame(x: x, y: 100, width: 80, height: 40), native: .android(AndroidNativeAttributes(resourceId: id)))
    }

    private static func roots(_ children: [UINode]) -> [UINode] {
        [UINode(role: .application, frame: UIFrame(x: 0, y: 0, width: 400, height: 800), native: .android(AndroidNativeAttributes()), children: children)]
    }

    @Test("--id alert_title finds com.x:id/alert_title when no id matches exactly")
    func suffixMatch() throws {
        let match = try AccessibilityTargetResolver.resolveElement(
            roots: Self.roots([Self.button("android:id/button1", x: 0), Self.button("com.x:id/alert_title", x: 100)]),
            query: .id("alert_title")
        )
        #expect(match.element.id == "com.x:id/alert_title")
    }

    @Test("an exact id wins over a native id with the same name")
    func exactWins() throws {
        let match = try AccessibilityTargetResolver.resolveElement(
            roots: Self.roots([Self.button("com.x:id/button1", x: 0), Self.button("button1", x: 100)]),
            query: .id("button1")
        )
        #expect(match.element.frame?.x == 100)
    }

    @Test("two native ids with the same name are ambiguous")
    func twoSuffixMatchesAreAmbiguous() {
        #expect(throws: ElementResolutionError.self) {
            try AccessibilityTargetResolver.resolveElement(
                roots: Self.roots([Self.button("android:id/button1", x: 0), Self.button("com.x:id/button1", x: 100)]),
                query: .id("button1")
            )
        }
    }

    @Test("a partial name is not a match")
    func partialNameIsNotAMatch() {
        #expect(throws: ElementResolutionError.self) {
            try AccessibilityTargetResolver.resolveElement(
                roots: Self.roots([Self.button("com.x:id/alert_title", x: 0)]),
                query: .id("title")
            )
        }
    }
}
