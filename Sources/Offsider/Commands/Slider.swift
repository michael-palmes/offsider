import ArgumentParser
import Foundation
import OffsiderCore

struct Slider: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set a slider to a deterministic value from 0 to 100 using accessibility selector targeting."
    )

    private static let directDragSteps = 120
    private static let directDragDuration: TimeInterval = 2.4
    private static let directDragInitialHold: TimeInterval = 0.05
    private static let directDragFinalHold: TimeInterval = 0.2
    private static let verificationTimeout: TimeInterval = 1.5
    private static let verificationPollInterval: TimeInterval = 0.1
    private static let verificationStabilityDelay: TimeInterval = 0.3
    private static let valueTolerance = 0.0007
    private static let alreadyAtTargetTolerance = valueTolerance
    private static let lowRangeCoordinateOffset = 0.0268
    private static let highRangeCoordinateOffset = 0.0271

    @Option(name: [.customLong("id")], help: "Set the slider whose describe-ui id matches (accessibilityIdentifier, or testID in React Native).")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Set the slider whose describe-ui label matches (accessibilityLabel).")
    var elementLabel: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to this describe-ui role (any case, usually slider) or native type.")
    var elementType: String?

    @Option(name: [.customLong("value")], help: "Target slider value as a percentage from 0 to 100.")
    var value: Double

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the slider before failing (0 = no waiting, default).")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    var pollInterval: Double = 0.25

    @Flag(name: .customLong("allow-offscreen"), help: "Resolve elements whose frame is outside the screen (off by default: selectors prefer on-screen matches).")
    var allowOffscreen: Bool = false

    @Flag(name: .customLong("no-settle"), help: "Set the slider at once, without waiting out a transition an input under 500 ms ago may have started.")
    var noSettle: Bool = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        let selectorCount = [elementID != nil, elementLabel != nil].filter { $0 }.count
        guard selectorCount == 1 else {
            throw ValidationError("Use exactly one of --id or --label to target a slider.")
        }
        try SelectorQuery.validate(id: elementID, label: elementLabel, value: nil)

        guard value.isFinite, (0...100).contains(value) else {
            throw ValidationError("--value must be a finite number between 0 and 100.")
        }
        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }
        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let line = try await setSlider(on: SliderTarget(backend: route.backend, device: route.device), logger: logger)
        logger.info().log("Slider set completed successfully")
        print(line)
    }

    /// Resolves, sets and verifies the slider, and returns the success line.
    func setSlider(on target: SliderTarget, logger: OffsiderLogger) async throws -> String {
        try await target.backend.prepare()

        let query = try accessibilityQuery()
        let targetNormalized = value / 100.0

        let polled = try await AccessibilityPoller.resolveElementWithPolling(
            query: query,
            on: target.backend,
            device: target.device,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            elementType: elementType,
            allowOffscreen: allowOffscreen,
            settle: noSettle ? .off : .guarded(record: await TreeCache.load(for: target.device, backend: target.backend)),
            logger: logger
        )

        let result = try await setAndVerifySliderValue(
            initialMatch: polled.value,
            initialTree: polled.tree,
            query: query,
            targetNormalized: targetNormalized,
            target: target,
            logger: logger
        )

        guard let nearestStep = result.nearestStep else {
            return "✓ Slider set to \(formatPercent(value)) successfully (value: \(result.observed))"
        }
        return "✓ Slider set to \(formatPercent(nearestStep)) (the nearest step to \(formatPercent(value))) successfully (value: \(result.observed))"
    }

    private func accessibilityQuery() throws -> AccessibilityQuery {
        guard let query = SelectorQuery.make(id: elementID, label: elementLabel, value: nil) else {
            throw CLIError(errorDescription: "Unexpected state: no slider selector.", reason: .internalError)
        }
        return query
    }

    private func requireSlider(_ element: UINode) throws {
        guard element.isSlider else {
            let typeDescription = element.native.typeName ?? element.role.rawValue
            throw CLIError(errorDescription: "Matched element is not a slider (type: \(typeDescription)). Use --element-type slider or a more specific --id/--label selector.", reason: .notASlider)
        }
    }

    private func makeDragPlan(
        for element: UINode,
        applicationFrame: UIFrame?,
        targetNormalized: Double
    ) throws -> SliderDragPlan {
        try requireSlider(element)
        guard let frame = element.frame else {
            throw ElementResolutionError.invalidFrame(reason: "Matched slider has no frame.")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw ElementResolutionError.invalidFrame(reason: "Matched slider has an invalid frame size (\(frame.width)x\(frame.height)).")
        }

        let currentNormalized = try parseNormalizedValue(element.normalizedValue)
        let centerY = frame.y + (frame.height / 2.0)
        let commandedNormalized = Self.commandedNormalizedValue(
            currentNormalized: currentNormalized,
            targetNormalized: targetNormalized
        )
        let nominalStartX = frame.x + (frame.width * currentNormalized)
        let startX = dragStartX(
            frame: frame,
            nominalStartX: nominalStartX,
            currentNormalized: currentNormalized,
            targetNormalized: targetNormalized
        )
        let fingerOffsetFromNominalStart = startX - nominalStartX
        let rawEndX = frame.x + (frame.width * commandedNormalized) + fingerOffsetFromNominalStart
        let endX = Self.clampedDragEndX(rawEndX, applicationFrame: applicationFrame)
        return SliderDragPlan(
            logicalStart: (x: startX, y: centerY),
            logicalEnd: (x: endX, y: centerY),
            currentNormalized: currentNormalized,
            targetNormalized: targetNormalized,
            commandedNormalized: commandedNormalized
        )
    }

    private func setAndVerifySliderValue(
        initialMatch: AccessibilityMatch,
        initialTree: UITree,
        query: AccessibilityQuery,
        targetNormalized: Double,
        target: SliderTarget,
        logger: OffsiderLogger
    ) async throws -> SliderResult {
        var initialMatch = initialMatch
        var initialTree = initialTree
        if let actions = target.backend as? any AccessibilityActionPerforming {
            try requireSlider(initialMatch.element)
            var outcome = try await actions.setRangeValue(targetNormalized, of: initialMatch.element, on: target.device)
            if outcome == .stale {
                logger.info().log("Slider \(initialMatch.selectorDescription) changed before it could be set; finding it again")
                (initialMatch, initialTree) = try await resolveSliderElementAndTree(query: query, on: target)
                outcome = try await actions.setRangeValue(targetNormalized, of: initialMatch.element, on: target.device)
            }
            switch outcome {
            case .performed(let reachable):
                return try await verifyActionResult(reachable: reachable, targetNormalized: targetNormalized, query: query, target: target, logger: logger)
            case .stale:
                throw CLIError(errorDescription: "The slider matched by \(selectorArgument) changed while Offsider was setting it. Retry when the screen is still.", reason: .targetMoved)
            case .unsupported(let reason):
                logger.info().log("Slider \(initialMatch.selectorDescription) cannot be set through accessibility (\(reason)); dragging it instead")
            }
        }

        let dragPlan = try makeDragPlan(
            for: initialMatch.element,
            applicationFrame: initialMatch.applicationFrame,
            targetNormalized: targetNormalized
        )
        logger.info().log(
            "Setting slider \(initialMatch.selectorDescription) from value \(formatNormalized(dragPlan.currentNormalized)) toward \(formatNormalized(dragPlan.targetNormalized)) with low-level HID drag"
        )

        if abs(dragPlan.currentNormalized - targetNormalized) > Self.alreadyAtTargetTolerance {
            try await performSliderDrag(dragPlan, tree: initialTree, on: target)
        }

        let observedValue = try await pollObservedSliderValue(
            query: query,
            targetNormalized: targetNormalized,
            on: target
        )
        guard observedValue.isWithinTolerance else {
            throw CLIError(
                errorDescription: "Slider value did not reach requested value \(formatPercent(value)) after direct drag. Observed value: \(observedValue.rawValue ?? "none").",
                reason: .sliderUnverified
            )
        }
        return SliderResult(observed: observedValue.rawValue ?? formatNormalized(observedValue.normalizedValue), nearestStep: nil)
    }

    /// After the device's own range action: verify against the step it can show, which may differ from the request.
    private func verifyActionResult(
        reachable: Double,
        targetNormalized: Double,
        query: AccessibilityQuery,
        target: SliderTarget,
        logger: OffsiderLogger
    ) async throws -> SliderResult {
        logger.info().log("Set the slider to \(formatNormalized(reachable)) through its accessibility action")
        let observedValue = try await pollObservedSliderValue(query: query, targetNormalized: reachable, on: target)
        guard observedValue.isWithinTolerance else {
            throw CLIError(
                errorDescription: "Slider value did not reach requested value \(formatPercent(value)) after its accessibility action. Observed value: \(observedValue.rawValue ?? "none").",
                reason: .sliderUnverified
            )
        }
        let nearestStep = abs(reachable - targetNormalized) > Self.valueTolerance ? (reachable * 10_000).rounded() / 100 : nil
        return SliderResult(observed: observedValue.rawValue ?? formatNormalized(observedValue.normalizedValue), nearestStep: nearestStep)
    }

    private var selectorArgument: String {
        if let elementID { return "--id '\(elementID)'" }
        return "--label '\(elementLabel ?? "")'"
    }

    /// `tree` is the one the slider was resolved from, so iOS needs no second read for the application frame.
    private func performSliderDrag(_ dragPlan: SliderDragPlan, tree: UITree, on target: SliderTarget) async throws {
        let physicalPoints = try await target.backend.deviceCoordinates(
            for: [dragPlan.logicalStart, dragPlan.logicalEnd],
            tree: tree,
            on: target.device
        )
        let physicalStart = physicalPoints[0]
        let physicalEnd = physicalPoints[1]

        let dragEvent = try InputEvent.compositeDrag(
            from: physicalStart,
            to: physicalEnd,
            duration: Self.directDragDuration,
            steps: Self.directDragSteps,
            initialHold: Self.directDragInitialHold,
            finalHold: Self.directDragFinalHold
        )
        try await target.backend.performTracked(dragEvent, on: target.device)
    }

    private func resolveSliderElement(query: AccessibilityQuery, on target: SliderTarget) async throws -> AccessibilityMatch {
        try await resolveSliderElementAndTree(query: query, on: target).match
    }

    private func resolveSliderElementAndTree(query: AccessibilityQuery, on target: SliderTarget) async throws -> (match: AccessibilityMatch, tree: UITree) {
        let tree = try await target.backend.accessibilityTree(for: target.device)
        let match = try AccessibilityTargetResolver.resolveElement(
            roots: tree.roots,
            query: query,
            elementType: elementType,
            allowOffscreen: allowOffscreen
        )
        guard match.element.isSlider else {
            throw CLIError(errorDescription: "Matched element is no longer a slider.", reason: .notASlider)
        }
        return (match, tree)
    }

    private func pollObservedSliderValue(
        query: AccessibilityQuery,
        targetNormalized: Double,
        on target: SliderTarget
    ) async throws -> SliderObservedValue {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(Self.verificationTimeout)
        var lastObservedValue: SliderObservedValue?

        repeat {
            let match = try await resolveSliderElement(query: query, on: target)
            let rawValue = match.element.normalizedValue
            let normalizedValue = try parseNormalizedValue(rawValue)
            let observedValue = SliderObservedValue(
                match: match,
                rawValue: rawValue,
                normalizedValue: normalizedValue,
                isWithinTolerance: abs(normalizedValue - targetNormalized) <= Self.valueTolerance
            )
            if observedValue.isWithinTolerance {
                try await Task.sleep(for: .seconds(Self.verificationStabilityDelay))
                if clock.now >= deadline {
                    return observedValue
                }
                let stableMatch = try await resolveSliderElement(query: query, on: target)
                let stableRawValue = stableMatch.element.normalizedValue
                let stableNormalizedValue = try parseNormalizedValue(stableRawValue)
                let stableObservedValue = SliderObservedValue(
                    match: stableMatch,
                    rawValue: stableRawValue,
                    normalizedValue: stableNormalizedValue,
                    isWithinTolerance: abs(stableNormalizedValue - targetNormalized) <= Self.valueTolerance
                )
                if stableObservedValue.isWithinTolerance {
                    return stableObservedValue
                }
                lastObservedValue = stableObservedValue
            } else {
                lastObservedValue = observedValue
            }

            if clock.now < deadline {
                try await Task.sleep(for: .seconds(Self.verificationPollInterval))
            }
        } while clock.now < deadline

        if let lastObservedValue {
            return lastObservedValue
        }
        throw CLIError(errorDescription: "Slider value could not be verified because its value was unavailable after dragging.", reason: .sliderUnverified)
    }

    private func dragStartX(
        frame: UIFrame,
        nominalStartX: Double,
        currentNormalized: Double,
        targetNormalized: Double
    ) -> Double {
        guard currentNormalized >= 1.0 - Self.valueTolerance, targetNormalized < currentNormalized else {
            return nominalStartX
        }
        return nominalStartX - (frame.height / 2.0)
    }

    static func commandedNormalizedValue(currentNormalized: Double, targetNormalized: Double) -> Double {
        if abs(currentNormalized - targetNormalized) <= Self.alreadyAtTargetTolerance {
            return currentNormalized
        }
        if targetNormalized < currentNormalized {
            return targetNormalized - Self.lowRangeCoordinateOffset
        }
        return targetNormalized + Self.highRangeCoordinateOffset
    }

    static func clampedDragEndX(
        _ x: Double,
        applicationFrame: UIFrame?
    ) -> Double {
        guard let applicationFrame, applicationFrame.width > 0 else {
            return x
        }
        return min(max(x, applicationFrame.x), applicationFrame.x + applicationFrame.width)
    }

    private func parseNormalizedValue(_ rawValue: String?) throws -> Double {
        guard let rawValue else {
            throw CLIError(errorDescription: "Matched slider does not expose a numeric value, so Offsider cannot deterministically set it.", reason: .sliderUnreadable)
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw CLIError(errorDescription: "Matched slider does not expose a numeric value, so Offsider cannot deterministically set it.", reason: .sliderUnreadable)
        }

        let isPercent = trimmedValue.hasSuffix("%")
        let numericText = trimmedValue.replacingOccurrences(of: "%", with: "")
        guard let parsedValue = Double(numericText.trimmingCharacters(in: .whitespacesAndNewlines)), parsedValue.isFinite else {
            throw CLIError(errorDescription: "Matched slider does not expose a numeric value, so Offsider cannot deterministically set it.", reason: .sliderUnreadable)
        }

        let normalizedValue = isPercent || parsedValue > 1.0 ? parsedValue / 100.0 : parsedValue
        guard (0...1).contains(normalizedValue) else {
            throw CLIError(errorDescription: "Matched slider value is outside the supported 0...100 range: \(rawValue).", reason: .sliderUnreadable)
        }
        return normalizedValue
    }

    private func formatPercent(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func formatNormalized(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

struct SliderTarget {
    let backend: any DeviceBackend
    let device: DeviceID
}

private struct SliderResult {
    let observed: String
    /// The percentage reached when the control's steps cannot show the requested value.
    let nearestStep: Double?
}

private struct SliderDragPlan {
    let logicalStart: (x: Double, y: Double)
    let logicalEnd: (x: Double, y: Double)
    let currentNormalized: Double
    let targetNormalized: Double
    let commandedNormalized: Double
}

private struct SliderObservedValue {
    let match: AccessibilityMatch
    let rawValue: String?
    let normalizedValue: Double
    let isWithinTolerance: Bool
}
