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

    @Test("a partly visible frame whose centre is off screen fails")
    func partlyVisibleCentreOffScreen() {
        let roots = Self.screen([Self.save(y: 830)])

        let error = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Save"))
        }

        #expect(error?.isOffScreen == true)
    }

    @Test("ambiguous on-screen matches list each candidate and the ignored off-screen ones")
    func multipleMatchesListCandidates() {
        let roots = Self.screen([Self.save(id: "save-a", y: 700), Self.save(y: 760), Self.save(y: 10700)])

        let message = Self.resolutionError {
            _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Save"))
        }?.userFacingDescription ?? ""

        #expect(message.hasPrefix("Multiple (2) accessibility elements matched --label 'Save' on screen: button id=save-a (20, 700) 350x44; button (20, 760) 350x44 (1 more off screen ignored). Use --id when labels are not unique."))
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

        #expect(message.contains("on screen: button id=save (20, 700) 350x44; button id=save (20, 760) 350x44. The id is not unique on this screen: narrow with --element-type, or tap one by coordinates (tap -x/-y) using the frames above."))
        #expect(!message.contains("Use --id"))
    }

    // MARK: Cover detection

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

        #expect(AccessibilityTargetResolver.confirmedCover(hit: text, resolution: resolution, roots: roots) == nil)
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

        #expect(AccessibilityTargetResolver.confirmedCover(hit: Self.banner, resolution: resolution, roots: roots) == nil)
    }

    @Test("a hit-test that finds a candidate confirms it, and a failed read falls back to the first candidate")
    func hitOnCandidateIsCover() throws {
        let roots = Self.bannerBeforeTabs()
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("tab-search"))

        #expect(AccessibilityTargetResolver.confirmedCover(hit: Self.banner, resolution: resolution, roots: roots)?.id == "banner")
        #expect(AccessibilityTargetResolver.confirmedCover(hit: nil, resolution: resolution, roots: roots)?.id == "banner")
        let tab = Self.tabBar().children[1]
        #expect(AccessibilityTargetResolver.confirmedCover(hit: tab, resolution: resolution, roots: roots) == nil)
    }

    @Test("without a hit-test, a candidate lying wholly inside the target is taken to be underneath it")
    func unconfirmedCandidateInsideTargetIsNoCover() throws {
        let roots = Self.bannerBeforeTabs()
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("banner"))

        #expect(resolution.coverCandidates.map(\.id) == ["tab-search"])
        #expect(AccessibilityTargetResolver.confirmedCover(hit: nil, resolution: resolution, roots: roots) == nil)
    }

    private func decodeElements(_ json: String) throws -> [UINode] {
        try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8))
    }
}
