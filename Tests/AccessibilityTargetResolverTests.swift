import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Accessibility Target Resolver Tests")
struct AccessibilityTargetResolverTests {
    @Test("Selector tap point uses contained switch activation frame")
    func selectorTapPointUsesContainedSwitchActivationFrame() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "AXLabel": "Weather Alerts",
                "children": [
                  {
                    "type": "Switch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXLabel": "Weather Alerts",
                    "AXUniqueId": "weather-alerts-switch"
                  }
                ]
              }
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Weather Alerts"))

        #expect(point.x == 325)
        #expect(point.y == 125)
    }

    @Test("Matched row uses contained switch with different label")
    func matchedRowUsesContainedSwitchWithDifferentLabel() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "AXLabel": "Weather Alerts",
                "children": [
                  {
                    "type": "Switch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXLabel": "Off"
                  }
                ]
              }
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Weather Alerts"))

        #expect(point.x == 325)
        #expect(point.y == 125)
    }

    @Test("Matched label uses sibling switch in nearest container")
    func matchedLabelUsesSiblingSwitchInNearestContainer() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 120, "width": 140, "height": 20 },
                    "AXLabel": "Weather Alerts"
                  },
                  {
                    "type": "CheckBox",
                    "role_description": "switch",
                    "subrole": "AXSwitch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXValue": "0"
                  }
                ]
              }
            ]
            """
        )

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Weather Alerts"))

        #expect(resolution.point.x == 325)
        #expect(resolution.point.y == 125)
        #expect(resolution.isSwitchLikeControl)
    }

    @Test("Matched label ignores nested sibling switch descendants")
    func matchedLabelIgnoresNestedSiblingSwitchDescendants() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 100 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 120, "width": 140, "height": 20 },
                    "AXLabel": "Weather Alerts"
                  },
                  {
                    "type": "Cell",
                    "frame": { "x": 220, "y": 110, "width": 150, "height": 60 },
                    "children": [
                      {
                        "type": "Switch",
                        "frame": { "x": 300, "y": 125, "width": 50, "height": 30 },
                        "AXLabel": "Unrelated Nested Switch"
                      }
                    ]
                  }
                ]
              }
            ]
            """
        )

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Weather Alerts"))

        #expect(resolution.point.x == 86)
        #expect(resolution.point.y == 130)
        #expect(!resolution.isSwitchLikeControl)
    }

    @Test("Wide switch-like rows use trailing activation point")
    func wideSwitchLikeRowsUseTrailingActivationPoint() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "CheckBox",
                "role_description": "switch",
                "subrole": "AXSwitch",
                "frame": { "x": 16, "y": 180, "width": 370, "height": 28 },
                "AXLabel": "SwiftUI Weather Alerts",
                "AXValue": "0"
              }
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("SwiftUI Weather Alerts"))

        #expect(point.x == 355)
        #expect(point.y == 194)
    }

    @Test("Identifier matching accepts AXIdentifier when AXUniqueId is missing")
    func identifierMatchingAcceptsAXIdentifier() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Switch",
                "frame": { "x": 10, "y": 20, "width": 40, "height": 20 },
                "AXLabel": "Weather Alerts",
                "AXIdentifier": "weather-alerts-switch"
              }
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .id("weather-alerts-switch"))

        #expect(point.x == 30)
        #expect(point.y == 30)
    }

    @Test("Duplicate AXIdentifier does not identify a different ancestor")
    func duplicateAXIdentifierDoesNotIdentifyDifferentAncestor() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 120, "width": 140, "height": 20 },
                    "AXLabel": "Unrelated Label",
                    "AXIdentifier": "shared-label-id"
                  },
                  {
                    "type": "Switch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXLabel": "Unrelated Switch"
                  }
                ]
              },
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 200, "width": 390, "height": 60 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 220, "width": 140, "height": 20 },
                    "AXLabel": "Weather Alerts",
                    "AXIdentifier": "shared-label-id"
                  },
                  {
                    "type": "Switch",
                    "frame": { "x": 100, "y": 210, "width": 50, "height": 30 },
                    "AXLabel": "Weather Alerts Switch"
                  }
                ]
              }
            ]
            """
        )

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Weather Alerts"))

        #expect(resolution.point.x == 125)
        #expect(resolution.point.y == 225)
        #expect(resolution.isSwitchLikeControl)
    }

    @Test("Elements with same type and frame but different roles are distinct")
    func elementsWithSameTypeAndFrameButDifferentRolesAreDistinct() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Cell",
                "frame": { "x": 0, "y": 100, "width": 390, "height": 60 },
                "children": [
                  {
                    "type": "StaticText",
                    "frame": { "x": 16, "y": 120, "width": 140, "height": 20 },
                    "AXValue": "1"
                  },
                  {
                    "type": "CheckBox",
                    "role_description": "switch",
                    "subrole": "AXSwitch",
                    "frame": { "x": 300, "y": 110, "width": 50, "height": 30 },
                    "AXValue": "0"
                  }
                ]
              }
            ]
            """
        )

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .value("1"))

        #expect(resolution.point.x == 86)
        #expect(resolution.point.y == 130)
        #expect(!resolution.isSwitchLikeControl)
    }

    @Test("Resolved element preserves slider frame and AXValue")
    func resolvedElementPreservesSliderFrameAndAXValue() throws {
        let roots = try decodeElements(
            """
            [
              {
                "type": "Slider",
                "role": "AXSlider",
                "frame": { "x": 40, "y": 200, "width": 300, "height": 40 },
                "AXLabel": "Volume",
                "AXUniqueId": "volume-slider",
                "AXValue": "0.25"
              }
            ]
            """
        )

        let match = try AccessibilityTargetResolver.resolveElement(roots: roots, query: .label("Volume"), elementType: "Slider")

        #expect(match.selectorDescription == "--label 'Volume'")
        #expect(match.element.role == .slider)
        #expect(match.element.frame?.x == 40)
        #expect(match.element.normalizedValue == "0.25")
    }

    @Test("--element-type matches the neutral role in any case or the native type exactly", arguments: [
        ("Slider", true), ("slider", true), ("SLIDER", true), ("Other", true), ("other", false), ("AXSlider", false),
    ])
    func elementTypeMatchesRoleOrNativeType(elementType: String, matches: Bool) throws {
        let roots = try decodeElements(
            """
            [{"type": "Other", "role": "AXSlider", "frame": {"x": 0, "y": 0, "width": 100, "height": 20}, "AXLabel": "Volume"}]
            """
        )

        let resolve = { try AccessibilityTargetResolver.resolveElement(roots: roots, query: .label("Volume"), elementType: elementType) }
        if matches {
            #expect(try resolve().element.role == .slider)
        } else {
            #expect(throws: ElementResolutionError.self) { try resolve() }
        }
    }

    @Test("--element-type accepts a native type name such as RadioButton or TextEditor")
    func elementTypeAcceptsNativeTypeName() throws {
        let roots = try decodeElements(
            """
            [
              {"type": "RadioButton", "frame": {"x": 0, "y": 0, "width": 80, "height": 40}, "AXLabel": "Home"},
              {"type": "StaticText", "frame": {"x": 0, "y": 50, "width": 80, "height": 40}, "AXLabel": "Home"},
              {"type": "TextEditor", "frame": {"x": 0, "y": 100, "width": 300, "height": 120}, "AXLabel": "Notes"},
              {"type": "TextView", "frame": {"x": 0, "y": 300, "width": 300, "height": 120}, "AXLabel": "Notes"}
            ]
            """
        )

        let radio = try AccessibilityTargetResolver.resolveElement(roots: roots, query: .label("Home"), elementType: "RadioButton")
        let editor = try AccessibilityTargetResolver.resolveElement(roots: roots, query: .label("Notes"), elementType: "TextEditor")

        #expect(radio.element.frame?.y == 0)
        #expect(editor.element.frame?.y == 100)
    }

    @Test("A text area is preferred over static text with the same label")
    func textAreaIsActionableForLabelMatching() throws {
        let roots = try decodeElements(
            """
            [
              {"type": "StaticText", "frame": {"x": 16, "y": 100, "width": 120, "height": 20}, "AXLabel": "Notes"},
              {"type": "TextEditor", "frame": {"x": 16, "y": 130, "width": 300, "height": 120}, "AXLabel": "Notes"}
            ]
            """
        )

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Notes"))

        #expect(point.x == 166)
        #expect(point.y == 190)
    }

    @Test("Ambiguous matches without ids suggest coordinates and name the neutral id")
    func ambiguousMatchesWithoutIDsUseNeutralWording() throws {
        let roots = try decodeElements(
            """
            [
              {"type": "Button", "frame": {"x": 0, "y": 0, "width": 80, "height": 40}, "AXLabel": "Save"},
              {"type": "Button", "frame": {"x": 0, "y": 50, "width": 80, "height": 40}, "AXLabel": "Save"}
            ]
            """
        )

        do {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Save"))
            Issue.record("Expected an ambiguous match error")
        } catch let error as ElementResolutionError {
            let message = error.userFacingDescription
            #expect(message.contains("none of the matches expose an id on this screen"))
            #expect(!message.contains("AX"))
        }
    }

    // MARK: On-screen preference

    static func screen(width: Double = 393, height: Double = 852, _ children: [UINode]) -> [UINode] {
        FakeUI.tree(width: width, height: height, children).roots
    }

    private static func save(id: String? = nil, y: Double, height: Double = 44) -> UINode {
        FakeUI.node(.button, id: id, label: "Save", frame: FakeUI.frame(20, y, 350, height))
    }

    private static func resolutionError(_ body: () throws -> Void) -> ElementResolutionError? {
        do {
            try body()
            return nil
        } catch {
            return error as? ElementResolutionError
        }
    }

    @Test("a parked duplicate off screen does not make an on-screen label ambiguous")
    func parkedDuplicateIgnored() throws {
        let roots = Self.screen([Self.save(y: 700), Self.save(y: 10700)])

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Save"))

        #expect(point.x == 195 && point.y == 722)
    }

    @Test("a single off-screen match fails with its frame and the screen size")
    func singleOffScreenMatchFails() {
        let roots = Self.screen([Self.save(id: "parked-sheet-test-apply", y: 10700)])

        let error = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("parked-sheet-test-apply"))
        }

        #expect(error?.isOffScreen == true)
        let message = error?.userFacingDescription ?? ""
        #expect(message.hasPrefix("Matched --id 'parked-sheet-test-apply' is off screen: its frame (20, 10700) 350x44 is outside the 393x852 screen"))
        #expect(message.contains("--allow-offscreen"))
        #expect(message.hasSuffix(AccessibilityTargetResolver.describeUITip))
    }

    @Test("a partly visible element whose centre is off screen is tapped at the centre of its visible part")
    func partlyVisibleTapsVisiblePart() throws {
        let roots = Self.screen([Self.save(id: "save", y: 832, height: 60)])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("save"))

        #expect(resolution.point.x == 195 && resolution.point.y == 842)
    }

    @Test("a wide switch whose trailing edge is off screen falls back to the centre of its visible part")
    func partlyVisibleSwitchFallsBack() throws {
        let toggle = FakeUI.node(.switch, id: "wifi", label: "Wi-Fi", frame: FakeUI.frame(200, 400, 393, 44))
        let roots = Self.screen([toggle])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("wifi"))

        #expect(resolution.point.x == 296.5 && resolution.point.y == 422)
    }

    @Test("several off-screen matches are all listed")
    func severalOffScreenMatchesListed() {
        let roots = Self.screen([Self.save(y: 10700), Self.save(y: 11200)])

        let message = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Save"))
        }?.userFacingDescription ?? ""

        #expect(message.hasPrefix("All 2 matches for --label 'Save' are off screen: (20, 10700) 350x44, (20, 11200) 350x44"))
        #expect(message.contains("393x852"))
    }

    @Test("--allow-offscreen restores matching off-screen elements")
    func allowOffscreenRestoresOldBehaviour() throws {
        let both = Self.screen([Self.save(y: 700), Self.save(y: 10700)])
        let ambiguous = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: both, query: .label("Save"), allowOffscreen: true)
        }
        guard case .multipleMatches(let count, _, _, _, _, _, _)? = ambiguous else {
            Issue.record("expected multipleMatches, got \(String(describing: ambiguous))")
            return
        }
        #expect(count == 2)

        let parked = Self.screen([Self.save(y: 10700)])
        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: parked, query: .label("Save"), allowOffscreen: true)
        #expect(point.y == 10722)
    }

    @Test("a tree without an application root skips the screen check")
    func noApplicationRootSkipsCheck() throws {
        let roots = [Self.save(y: 10700)]

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Save"))

        #expect(point.y == 10722)
    }

    @Test("a key inside an Android keyboard root is on screen")
    func keyboardRootIsOnScreen() throws {
        let key = FakeUI.node(.button, label: "q", frame: FakeUI.frame(0, 650, 41, 50), platform: .android)
        let app = FakeUI.node(.application, frame: FakeUI.frame(0, 0, 412, 600), platform: .android)
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 600, 412, 315), platform: .android, children: [key])

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: [app, keyboard], query: .label("q"))

        #expect(point.x == 20.5 && point.y == 675)
    }

    @Test("a landscape viewport judges frames by its own width and height")
    func landscapeViewport() throws {
        let roots = Self.screen(width: 852, height: 393, [
            FakeUI.node(.button, label: "Inside", frame: FakeUI.frame(550, 180, 100, 40)),
            FakeUI.node(.button, label: "Below", frame: FakeUI.frame(550, 580, 100, 40)),
        ])

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Inside"))
        #expect(point.x == 600 && point.y == 200)

        let error = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Below"))
        }
        #expect(error?.isOffScreen == true)
    }

    @Test("ambiguous on-screen matches name each candidate's label and the ignored off-screen ones")
    func multipleMatchesListCandidates() {
        let roots = Self.screen([Self.save(id: "save-a", y: 700), Self.save(y: 760), Self.save(y: 10700)])

        let message = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Save"))
        }?.userFacingDescription ?? ""

        #expect(message.hasPrefix("Multiple (2) accessibility elements matched --label 'Save' on screen: button id=save-a label=\"Save\" (20, 700) 350x44 (--nth 1); button label=\"Save\" (20, 760) 350x44 (--nth 2) (1 more off screen ignored). Use --id when labels are not unique."))
    }

    // MARK: Folding and suggestions

    @Test("a straight apostrophe matches a curly one")
    func straightApostropheMatchesCurly() throws {
        let roots = Self.screen([FakeUI.node(.button, label: "Don\u{2019}t Allow", frame: FakeUI.frame(20, 400, 200, 44))])

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Don't Allow"))

        #expect(point.y == 422)
    }

    @Test("an exact label wins over a folded one without ambiguity")
    func exactBeatsFolded() throws {
        let roots = Self.screen([
            FakeUI.node(.button, label: "Don\u{2019}t Allow", frame: FakeUI.frame(20, 400, 200, 44)),
            FakeUI.node(.button, label: "Don't Allow", frame: FakeUI.frame(20, 500, 200, 44)),
        ])

        let point = try AccessibilityTargetResolver.resolveTapPoint(roots: roots, query: .label("Don't Allow"))

        #expect(point.y == 522)
    }

    @Test("ids are never folded")
    func idsAreExact() {
        let roots = Self.screen([FakeUI.node(.button, id: "don\u{2019}t", frame: FakeUI.frame(20, 400, 200, 44))])

        let error = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("don't"))
        }

        guard case .notFound? = error else {
            Issue.record("expected notFound, got \(String(describing: error))")
            return
        }
    }

    @Test("a missing label suggests close labels on the screen")
    func notFoundSuggestsLabels() {
        let roots = Self.screen([
            FakeUI.node(.button, label: "Sign In", frame: FakeUI.frame(20, 400, 200, 44)),
            FakeUI.node(.button, label: "Sign in with Apple", frame: FakeUI.frame(20, 500, 200, 44)),
            FakeUI.node(.button, label: "Cancel", frame: FakeUI.frame(20, 600, 200, 44)),
        ])

        let message = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Sign in"))
        }?.userFacingDescription ?? ""

        #expect(message.hasPrefix("No accessibility element matched --label 'Sign in'. Did you mean 'Sign In' or 'Sign in with Apple'? "))
        #expect(message.hasSuffix(AccessibilityTargetResolver.describeUITip))
    }

    @Test("a label removed by --element-type says which roles have it")
    func elementTypeHint() {
        let roots = Self.screen([
            FakeUI.node(.text, label: "Save", frame: FakeUI.frame(20, 400, 200, 44)),
            FakeUI.node(.text, label: "Save", frame: FakeUI.frame(20, 500, 200, 44)),
        ])

        let message = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Save"), elementType: "button")
        }?.userFacingDescription ?? ""

        #expect(message.hasPrefix("No accessibility element matched --label 'Save' with --element-type button: 2 elements have that label (roles: text)."))
    }

    @Test("a duplicate --id suggests --element-type or coordinates, not --id")
    func duplicateIDAdvice() {
        let roots = Self.screen([Self.save(id: "save", y: 700), Self.save(id: "save", y: 760)])

        let message = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("save"))
        }?.userFacingDescription ?? ""

        #expect(message.contains("on screen: button id=save label=\"Save\" (20, 700) 350x44 (--nth 1); button id=save label=\"Save\" (20, 760) 350x44 (--nth 2). The id is not unique on this screen: narrow with --element-type, or tap one by coordinates (tap -x/-y) using the frames above."))
        #expect(!message.contains("Use --id"))
    }

    // MARK: Cover detection

    /// What `CoverJudge` makes of a resolved tap, given a hit-test answer or none.
    static func judgedCover(hit: UINode?, resolution: TapResolution, roots: [UINode]) -> UINode? {
        guard let target = resolution.target, let matched = resolution.matched, let viewport = UITree.viewport(in: roots) else { return nil }
        return CoverJudge.judge(
            target: target, matched: matched, point: UIPoint(x: resolution.point.x, y: resolution.point.y), candidates: resolution.coverCandidates,
            roots: roots, viewport: viewport, stack: ScreenStack.build(roots: roots, viewport: viewport), hit: hit
        )?.cover
    }

    static let bannerLabel = "Connection lost. Can’t reach the server."

    static let banner = FakeUI.node(.other, id: "banner", label: bannerLabel, frame: FakeUI.frame(0, 767, 402, 107))

    static func tabBar() -> UINode {
        FakeUI.node(.tabBar, frame: FakeUI.frame(0, 790, 402, 84), children: [
            FakeUI.node(.button, id: "tab-home", label: "Home", frame: FakeUI.frame(0, 790, 134, 49)),
            FakeUI.node(.button, id: "tab-search", label: "Search", frame: FakeUI.frame(134, 790, 134, 49)),
        ])
    }

    /// The iOS shape: the banner is listed before the tabs it is drawn over.
    static func bannerBeforeTabs() -> [UINode] {
        screen(width: 402, height: 874, [banner, tabBar()])
    }

    @Test("a labelled banner listed before the tabs it covers is a candidate")
    func bannerBeforeTabsIsCandidate() throws {
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: Self.bannerBeforeTabs(), query: .id("tab-search"))

        #expect(resolution.point.x == 201 && resolution.point.y == 814.5)
        #expect(resolution.coverCandidates.map(\.id) == ["banner"])
    }

    @Test("a labelled banner listed after the tabs is a candidate too")
    func bannerAfterTabsIsCandidate() throws {
        let roots = Self.screen(width: 402, height: 874, [Self.tabBar(), Self.banner])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("tab-search"))

        #expect(resolution.coverCandidates.map(\.id) == ["banner"])
    }

    @Test("a control's own text, listed as a sibling inside its frame, is not a cover")
    func siblingTextInsideTargetIsNotCover() throws {
        let text = FakeUI.node(.text, label: "Dismiss", frame: FakeUI.frame(40, 800, 60, 20))
        let roots = Self.screen(width: 402, height: 874, [
            FakeUI.node(.other, label: "Dismiss", frame: FakeUI.frame(0, 790, 134, 49)),
            text,
        ])
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Dismiss"), elementType: "other")

        #expect(Self.judgedCover(hit: text, resolution: resolution, roots: roots) == nil)
    }

    @Test("tapping the banner itself lists the tab under its centre as a candidate")
    func tapsUnderBannerAreCandidates() throws {
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: Self.bannerBeforeTabs(), query: .id("banner"))

        #expect(resolution.coverCandidates.map(\.id) == ["tab-search"])
    }

    @Test("--allow-offscreen skips the cover check")
    func allowOffscreenSkipsCoverCheck() throws {
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: Self.bannerBeforeTabs(), query: .id("tab-search"), allowOffscreen: true)

        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("a tree without a screen skips the cover check")
    func noViewportSkipsCoverCheck() throws {
        let roots = Self.bannerBeforeTabs()[0].children

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("tab-search"))

        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("a text label inside the target button is not a candidate")
    func labelInsideTargetIsNotCandidate() throws {
        let roots = Self.screen([
            FakeUI.node(.button, id: "save", frame: FakeUI.frame(20, 700, 350, 44), children: [
                FakeUI.node(.text, label: "Save", frame: FakeUI.frame(150, 710, 90, 24)),
            ]),
        ])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("save"))

        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("an unlabelled full-screen group over the point is not a candidate")
    func unlabelledGroupIsNotCandidate() throws {
        let roots = Self.screen([
            Self.save(id: "save", y: 700),
            FakeUI.node(.group, frame: FakeUI.frame(0, 0, 393, 852)),
        ])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("save"))

        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("a labelled group over the point is a candidate, as Android maps a labelled banner")
    func labelledGroupIsCandidate() throws {
        let roots = Self.screen([
            FakeUI.node(.group, label: Self.bannerLabel, frame: FakeUI.frame(0, 650, 393, 202)),
            Self.save(id: "save", y: 700),
        ])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("save"))

        #expect(resolution.coverCandidates.map(\.label) == [Self.bannerLabel])
    }

    @Test("the labelled container holding the target is not a candidate")
    func ancestorIsNotCandidate() throws {
        let roots = Self.screen([
            FakeUI.node(.other, label: "Settings panel", frame: FakeUI.frame(0, 600, 393, 252), children: [
                Self.save(id: "save", y: 700),
            ]),
        ])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("save"))

        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("a keyboard root over the point is a candidate, wherever it is listed")
    func keyboardRootIsCandidate() throws {
        let app = Self.screen([Self.save(id: "save", y: 700)])[0]
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 560, 393, 292))

        let after = try AccessibilityTargetResolver.resolveTap(roots: [app, keyboard], query: .id("save"))
        let before = try AccessibilityTargetResolver.resolveTap(roots: [keyboard, app], query: .id("save"))

        #expect(after.coverCandidates.map(\.role) == [.keyboard])
        #expect(before.coverCandidates.map(\.role) == [.keyboard])
    }

    @Test("a hit-test that finds the target, or the label inside it, confirms no cover")
    func hitOnTargetIsNoCover() throws {
        let roots = Self.bannerBeforeTabs()
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("banner"))

        #expect(Self.judgedCover(hit: Self.banner, resolution: resolution, roots: roots) == nil)
    }

    @Test("a hit-test that finds a candidate confirms it, and a failed read falls back to the first candidate")
    func hitOnCandidateIsCover() throws {
        let roots = Self.bannerBeforeTabs()
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("tab-search"))

        #expect(Self.judgedCover(hit: Self.banner, resolution: resolution, roots: roots)?.id == "banner")
        #expect(Self.judgedCover(hit: nil, resolution: resolution, roots: roots)?.id == "banner")
        let tab = Self.tabBar().children[1]
        #expect(Self.judgedCover(hit: tab, resolution: resolution, roots: roots) == nil)
    }

    @Test("without a hit-test, a candidate lying wholly inside the target is taken to be underneath it")
    func unconfirmedCandidateInsideTargetIsNoCover() throws {
        let roots = Self.bannerBeforeTabs()
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("banner"))

        #expect(resolution.coverCandidates.map(\.id) == ["tab-search"])
        #expect(Self.judgedCover(hit: nil, resolution: resolution, roots: roots) == nil)
    }

    /// The Android shape of a bottom sheet: a labelled, clickable scrim fills the screen behind the sheet's buttons.
    static func sheetOverScrim(banner: UINode? = nil) -> [UINode] {
        let scrim = FakeUI.node(.button, label: "Dismiss", frame: FakeUI.frame(0, 0, 412, 915), platform: .android)
        let sheet = FakeUI.node(.other, frame: FakeUI.frame(0, 600, 412, 315), platform: .android, children: [
            FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(16, 840, 380, 48), platform: .android),
        ])
        let app = FakeUI.node(.application, frame: FakeUI.frame(0, 0, 412, 915), platform: .android, children: [scrim, sheet] + (banner.map { [$0] } ?? []))
        return [app]
    }

    @Test("without a hit-test, a full-screen scrim behind a sheet's button is not a cover")
    func scrimIsNotCover() throws {
        let roots = Self.sheetOverScrim()
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("apply"))

        #expect(resolution.coverCandidates.map(\.label) == ["Dismiss"])
        #expect(Self.judgedCover(hit: nil, resolution: resolution, roots: roots) == nil)
    }

    @Test("without a hit-test, a banner over a sheet's button is still a cover when a scrim lies behind both")
    func bannerOverScrimIsCover() throws {
        let banner = FakeUI.node(.other, label: Self.bannerLabel, frame: FakeUI.frame(0, 800, 412, 110), platform: .android)
        let roots = Self.sheetOverScrim(banner: banner)
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("apply"))

        #expect(Self.judgedCover(hit: nil, resolution: resolution, roots: roots)?.label == Self.bannerLabel)
    }

    /// The Android shape of a LogBox banner: its frame ends at 874, above a tab whose centre is at 875.
    static func logBoxOverTabs(label: String = "!, Request failed") -> [UINode] {
        let android = DevicePlatform.android
        let banner = FakeUI.node(.button, label: label, frame: FakeUI.frame(8, 810, 396, 64), platform: android, children: [
            FakeUI.node(.text, label: "!", frame: FakeUI.frame(20, 826, 32, 32), platform: android),
            FakeUI.node(.text, label: String(label.drop { $0 != " " }.dropFirst()), frame: FakeUI.frame(60, 826, 300, 32), platform: android),
            FakeUI.node(.button, frame: FakeUI.frame(364, 826, 32, 32), platform: android),
        ])
        let tabs = FakeUI.node(.other, frame: FakeUI.frame(0, 851, 412, 64), platform: android, children: [
            FakeUI.node(.button, id: "tab-home", label: "Home", frame: FakeUI.frame(0, 851, 137, 48), platform: android),
            FakeUI.node(.button, id: "tab-search", label: "Search", frame: FakeUI.frame(137, 851, 137, 48), platform: android),
        ])
        let above = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(16, 700, 380, 48), platform: android)
        return [FakeUI.node(.application, frame: FakeUI.frame(0, 0, 412, 915), platform: android, children: [above, tabs, banner])]
    }

    @Test("without a hit-test, a tab just below a LogBox banner's frame is covered by its touch area")
    func logBoxCoversTabBelowItsFrame() throws {
        let roots = Self.logBoxOverTabs()
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("tab-search"))

        #expect(resolution.point.y == 875)
        #expect(Self.judgedCover(hit: nil, resolution: resolution, roots: roots)?.label == "!, Request failed")
    }

    @Test("a target above a LogBox banner is not covered by it")
    func logBoxLeavesTargetAboveIt() throws {
        let roots = Self.logBoxOverTabs()
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("save"))

        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("a labelled button that is not a LogBox banner covers only its own frame")
    func ordinaryBannerCoversOnlyItsFrame() throws {
        let roots = Self.logBoxOverTabs(label: "3 unread")
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("tab-search"))

        #expect(Self.judgedCover(hit: nil, resolution: resolution, roots: roots) == nil)
    }

    private func decodeElements(_ json: String) throws -> [UINode] {
        try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8))
    }

    @Test("an ambiguous match lists up to five candidates with id, label, role, frame and on-screen state")
    func ambiguousCandidates() throws {
        let roots = Self.screen((0..<7).map { Self.save(id: "save", y: 100 + Double($0) * 60) })

        let error = try #require(Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("save"))
        })

        #expect(error.exitCode == .ambiguousSelector)
        #expect(error.reason == .selectorAmbiguous)
        #expect(error.candidates.count == 5)
        #expect(error.candidates[0] == FailureCandidate(id: "save", label: "Save", role: "button", frame: FakeUI.frame(20, 100, 350, 44), onScreen: true, index: 1, window: "Playground"))
    }

    @Test("not-found candidates are the elements behind the suggestions, and the miss exits 2")
    func notFoundCandidates() throws {
        let roots = Self.screen([
            FakeUI.node(.button, id: "log-in", label: "Log in", frame: FakeUI.frame(16, 620, 361, 50)),
            FakeUI.node(.text, id: "title", label: "Welcome", frame: FakeUI.frame(16, 100, 361, 30)),
        ])

        let error = try #require(Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("login"))
        })

        #expect(error.exitCode == .selectorNotFound)
        #expect(error.reason == .selectorNotFound)
        #expect(error.candidates == [FailureCandidate(id: "log-in", label: "Log in", role: "button", frame: FakeUI.frame(16, 620, 361, 50), onScreen: true)])
        #expect(error.hint == "offsider describe-ui --device <DEVICE_ID> --summary")
    }

    @Test("candidates never include an element's value, and a secure field is never a --value candidate")
    func candidatesCarryNoValue() throws {
        let sentinel = "S3NT1NEL-VALUE"
        let roots = Self.screen([
            FakeUI.node(.textField, id: "name", label: "Name", value: sentinel, frame: FakeUI.frame(16, 100, 361, 44)),
            FakeUI.node(.textField, id: "name", label: "Name", value: sentinel, frame: FakeUI.frame(16, 160, 361, 44)),
            FakeUI.node(.secureTextField, id: "password", label: "Password", value: "S3NT1NEL-VALUF", frame: FakeUI.frame(16, 220, 361, 44)),
        ])

        let ambiguous = try #require(Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("name"))
        })
        let payload = ErrorPayload(ambiguous, dispatched: .no)
        #expect(payload.candidates.count == 2)
        #expect(!payload.jsonLine().contains(sentinel))

        let missing = try #require(Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .value("S3NT1NEL-VALUE!"))
        })
        #expect(!missing.candidates.contains { $0.id == "password" })
    }

    @Test("a target-type filter, off screen and no frame keep their own reasons")
    func otherReasons() throws {
        let roots = Self.screen([FakeUI.node(.text, label: "Save", frame: FakeUI.frame(20, 700, 350, 44)), Self.save(id: "far", y: 10700)])
        let filtered = try #require(Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Save"), elementType: "switch")
        })
        let offScreen = try #require(Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("far"))
        })
        #expect(filtered.reason == .selectorFilteredByType && filtered.exitCode == .selectorNotFound)
        #expect(offScreen.reason == .targetOffScreen && offScreen.exitCode == .selectorNotFound)
        #expect(ElementResolutionError.invalidFrame(reason: "x").exitCode == .failure)
    }
}

@Suite("Stacked screens, --nth and --topmost")
struct StackedScreenTests {
    /// Two pages of a JavaScript stack, page 1 kept mounted under page 2 and offset to the left.
    static func stack(platform: DevicePlatform, hidePageOne: Bool = false) -> [UINode] {
        func page(_ number: Int, x: Double, visible: Bool = true) -> UINode {
            var back = FakeUI.node(.button, id: "stack-back", label: "Back", frame: FakeUI.frame(x + 16, 200, 120, 44), platform: platform)
            if !visible, case .android(var attributes) = back.native {
                attributes.visibleToUser = false
                back.native = .android(attributes)
            }
            return FakeUI.node(.other, id: "page-\(number)", label: "Page \(number)", frame: FakeUI.frame(x, 100, 402, 774), platform: platform, children: [back])
        }
        return FakeUI.tree(platform: platform, [page(1, x: -30, visible: !hidePageOne), page(2, x: 0)]).roots
    }

    @Test("on Android a sibling listed earlier may still be drawn on top, since Android sorts siblings by position")
    func earlierSiblingStaysCandidate() throws {
        let roots = Self.stack(platform: .android)
        let top = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Back"), pick: .last)
        #expect(top.coverCandidates.map(\.id) == ["page-1", "stack-back"])

        let beneath = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Back"), pick: .nth(1))
        #expect(beneath.coverCandidates.map(\.id) == ["page-2", "stack-back"])
    }

    @Test("on Android an app node beneath a keyboard window never covers a key, while the keyboard still covers the app")
    func lowerWindowIsNotCover() throws {
        let key = FakeUI.node(.button, label: "q", frame: FakeUI.frame(0, 650, 41, 50), platform: .android)
        let field = FakeUI.node(.button, label: "Pay", frame: FakeUI.frame(0, 640, 412, 70), platform: .android)
        let app = FakeUI.node(.application, frame: FakeUI.frame(0, 0, 412, 915), platform: .android, children: [field])
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 600, 412, 315), platform: .android, children: [key])

        let onKey = try AccessibilityTargetResolver.resolveTap(roots: [app, keyboard], query: .label("q"))
        #expect(onKey.coverCandidates.isEmpty)

        let onApp = try AccessibilityTargetResolver.resolveTap(roots: [app, keyboard], query: .label("Pay"))
        #expect(onApp.coverCandidates.map(\.role) == [.keyboard])
    }

    @Test("on Android a node not visible to the user is never a cover")
    func invisibleIsNotCover() throws {
        let roots = FakeUI.tree(platform: .android, [
            FakeUI.node(.button, id: "target", label: "Target", frame: FakeUI.frame(16, 200, 120, 44), platform: .android),
        ]).roots
        var hidden = FakeUI.node(.button, id: "hidden", label: "Hidden", frame: FakeUI.frame(0, 180, 402, 100), platform: .android)
        if case .android(var attributes) = hidden.native {
            attributes.visibleToUser = false
            hidden.native = .android(attributes)
        }
        var app = roots[0]
        app.children.append(hidden)

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: [app], query: .id("target"))
        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("--nth picks among on-screen matches in tree order, and past the end is not found")
    func nth() throws {
        let roots = Self.stack(platform: .ios)
        #expect(try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Back"), pick: .nth(2)).point.x == 76)
        #expect(try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Back"), pick: .nth(1)).matched?.frame?.x == -14)
        #expect(throws: ElementResolutionError.self) {
            try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Back"), pick: .nth(3))
        }
    }

    @Test("--nth past the end counts the matches in the singular and the plural", arguments: [(1, "is 1 match"), (3, "are 3 matches")])
    func nthOutOfRangeCount(count: Int, phrase: String) {
        let message = ElementResolutionError.nthOutOfRange(selector: "--label 'Back'", nth: 4, count: count).userFacingDescription
        #expect(message.hasPrefix("--nth 4 asked for match 4 of --label 'Back', but there \(phrase) on screen."))
    }

    @Test("an ambiguous match names each candidate's --nth, window and screen")
    func candidateContext() throws {
        let roots = Self.stack(platform: .android)
        let error = #expect(throws: ElementResolutionError.self) {
            try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Back"))
        }
        #expect(error?.candidates.map(\.index) == [1, 2])
        #expect(error?.candidates.map(\.screen) == ["page-1", "page-2"])
        #expect(error?.candidates.first?.window == "Playground")
    }

    static func golden(_ screen: String) throws -> [UINode] {
        try TreeGoldens.tree(of: TreeGoldens.Golden(platform: .android, screen: screen)).roots
    }

    @Test("several matches: the only one not beneath a page is taken")
    func onlyUncoveredMatch() throws {
        var tree = ScreenStackTests.nestedScreens()
        tree.roots[0].children[1].children.append(FakeUI.node(.button, label: "Dashboard Tab", frame: FakeUI.frame(201, 700, 201, 49)))

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .label("Dashboard Tab"))

        #expect(resolution.point.x == 301.5 && resolution.point.y == 724.5)
    }

    @Test("stacked Back buttons sharing one point: the one a touch there reaches is taken, drawn on top on Android")
    func samePointMatches() throws {
        let roots = try Self.golden("stack-test@flags")

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Back"))

        #expect(resolution.matched?.id == "stack-test-full-back-2")
    }

    @Test("matches at different points on the top screen stay ambiguous, each named with its screen and whether it is beneath")
    func ambiguousAcrossScreens() throws {
        var tree = ScreenStackTests.nestedScreens()
        tree.roots[0].children[1].children += [
            FakeUI.node(.button, label: "Dashboard Tab", frame: FakeUI.frame(201, 700, 201, 49)),
            FakeUI.node(.button, label: "Dashboard Tab", frame: FakeUI.frame(0, 600, 201, 49)),
        ]

        let error = #expect(throws: ElementResolutionError.self) {
            try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .label("Dashboard Tab"))
        }

        #expect(error?.candidates.map(\.screen) == ["Assets", "Bitcoin", "Bitcoin"])
        #expect(error?.candidates.map(\.beneath) == [true, false, false])
        #expect(error?.userFacingDescription.contains("in screen=Assets (beneath another screen) (--nth 1)") == true)
    }

    @Test("cover candidates leave out elements beneath the page and, on Android, those drawn below the target")
    func candidatesOnTop() throws {
        let roots = try Self.golden("stack-test@full")

        let buy = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("stack-test-full-buy"))
        let tab = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("stack-test-tab-dashboard"))

        #expect(buy.coverCandidates.isEmpty)
        #expect(tab.coverCandidates.map(\.id) == ["stack-test-full-buy"])
    }
}

