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

    private func decodeElements(_ json: String) throws -> [UINode] {
        try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8))
    }
}
