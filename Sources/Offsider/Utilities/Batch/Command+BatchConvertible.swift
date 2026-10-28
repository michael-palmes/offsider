import ArgumentParser
import Foundation
import OffsiderCore

@MainActor
protocol BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive]
}

@MainActor
private func resolveBatchTapPoint(
    query: AccessibilityQuery,
    context: BatchContext,
    waitTimeout: TimeInterval,
    pollInterval: TimeInterval,
    elementType: String?,
    allowOffscreen: Bool,
    settle: SettlePolicy,
    pick: MatchPicker?,
    coverCheck: AccessibilityPoller.CoverCheck?,
    logger: OffsiderLogger
) async throws -> Polled<TapResolution> {
    let fetchTree = context.pollingTreeSource()
    return try await AccessibilityPoller.pollForResolution(
        query: query,
        waitTimeout: waitTimeout,
        pollInterval: pollInterval,
        elementType: elementType,
        allowOffscreen: allowOffscreen,
        settle: settle,
        pick: pick,
        coverCheck: coverCheck,
        logger: logger
    ) {
        try await fetchTree()
    }
}

func parseCommaSeparatedIntsStrict(_ rawValue: String, fieldName: String) throws -> [Int] {
    let rawTokens = rawValue
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespaces) }

    let invalidTokens = rawTokens.filter { token in
        token.isEmpty || Int(token) == nil
    }
    guard invalidTokens.isEmpty else {
        throw ValidationError("All \(fieldName) must be valid integers. Invalid token(s): \(invalidTokens.joined(separator: ", "))")
    }

    return rawTokens.compactMap(Int.init)
}

extension Tap: BatchConvertible {
    private func resolvedTapStyle(for resolution: TapResolution, context: BatchContext) -> TapStyle {
        let requestedStyle = tapStyle ?? context.tapStyle
        switch requestedStyle {
        case .automatic:
            return resolution.isSwitchLikeControl ? .physical : .simulator
        case .simulator:
            return .simulator
        case .physical:
            return .physical
        }
    }

    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let resolution: TapResolution
        let resolvedTree: UITree?

        if let pointX, let pointY {
            resolution = TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false)
            resolvedTree = nil
            await Self.warnIfOffScreen(x: pointX, y: pointY, backend: context.backend, device: context.device)
        } else {
            guard let query else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.", reason: .internalError)
            }

            // A step's own --wait-timeout and --poll-interval override the batch-level values.
            let waitTimeout = self.waitTimeout ?? context.waitTimeout
            let pollInterval = self.pollInterval ?? context.pollInterval
            if waitTimeout > 0, pollInterval <= 0 {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
            let resolved = try await resolveBatchTapPoint(
                query: query,
                context: context,
                waitTimeout: waitTimeout,
                pollInterval: pollInterval,
                elementType: elementType,
                allowOffscreen: allowOffscreen,
                settle: context.settlePolicy(stepOptedOut: noSettle),
                pick: matchPicker(query: query, backend: context.backend, device: context.device),
                coverCheck: coverCheck(selector: query.selectorDescription, backend: context.backend, device: context.device),
                logger: logger
            )
            resolution = resolved.value
            resolvedTree = resolved.tree
            Self.warnIfOffScreen(subject: query.selectorDescription, at: resolution.point, in: resolved.tree)
        }

        let physicalPoint = try await context.backend.deviceCoordinates(
            for: [resolution.point],
            tree: resolvedTree,
            on: context.device
        )[0]

        let style = resolvedTapStyle(for: resolution, context: context)
        switch style {
        case .physical:
            return [.physicalTap(point: physicalPoint, preDelay: preDelay, postDelay: postDelay)]
        case .simulator:
            let tapEvent = InputEvent.tapAt(x: physicalPoint.x, y: physicalPoint.y)
            return [.hidMergeable(InputEvent.delayed(tapEvent, pre: preDelay, post: postDelay))]
        case .automatic:
            throw CLIError(errorDescription: "Unexpected tap style resolution.", reason: .internalError)
        }
    }
}

extension Swipe: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        guard !holdShots.isRequested else { throw ValidationError(HoldScreenshotOptions.batchMessage) }
        let physicalPoints = try await context.backend.deviceCoordinates(
            for: [(x: startX, y: startY), (x: endX, y: endY)],
            tree: nil,
            on: context.device
        )
        let event = try swipeEvent(from: physicalPoints[0], to: physicalPoints[1])
        return [.hidMergeable(InputEvent.delayed(event, pre: preDelay, post: postDelay))]
    }
}

extension Drag: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        guard !holdShots.isRequested else { throw ValidationError(HoldScreenshotOptions.batchMessage) }
        let physicalPoints = try await context.backend.deviceCoordinates(
            for: [(x: startX, y: startY), (x: endX, y: endY)],
            tree: nil,
            on: context.device
        )
        let event = try dragEvent(from: physicalPoints[0], to: physicalPoints[1])
        return [.hidMergeable(InputEvent.delayed(event, pre: preDelay, post: postDelay))]
    }
}

extension Gesture: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let gestureEvent = try await presetEvent(
            tree: { try await context.accessibilityTree() },
            backend: context.backend,
            device: context.device,
            logger: logger
        )
        return [.hidMergeable(InputEvent.delayed(gestureEvent, pre: preDelay, post: postDelay))]
    }
}

extension Touch: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        if fingers == 2 {
            return [.hidBarrier(try await twoFingerEvent(backend: context.backend, device: context.device))]
        }
        let physicalPoint = try await context.backend.deviceCoordinates(
            for: [(x: pointX, y: pointY)],
            tree: nil,
            on: context.device
        )[0]

        let touchDownEvent = InputEvent.touch(direction: .down, x: physicalPoint.x, y: physicalPoint.y)
        let touchUpEvent = InputEvent.touch(direction: .up, x: physicalPoint.x, y: physicalPoint.y)

        if touchDown && touchUp {
            let holdDelay = delay ?? TapTiming.defaultHoldDuration
            if context.device.isPhysicalIOSDevice || context.backend.platform == .android {
                // The session times the hold itself, as the standalone command does on these devices (older Android has no other way).
                return [.hidBarrier(.composite([touchDownEvent, .delay(holdDelay), touchUpEvent]))]
            }
            return [
                .hidBarrier(touchDownEvent),
                .hostSleep(holdDelay),
                .hidBarrier(touchUpEvent)
            ]
        }

        if touchDown {
            return [.hidMergeable(touchDownEvent)]
        }

        return [.hidMergeable(touchUpEvent)]
    }
}

extension Button: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let platform = context.backend.platform
        try Self.checkAvailability(buttonType, on: platform, device: context.device.rawValue, physicalIOS: context.device.isPhysicalIOSDevice)
        try Self.checkDuration(buttonType, duration: duration, on: platform)
        return [.hidMergeable(Self.pressEvent(buttonType, duration: duration, on: platform))]
    }
}

extension Key: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        try systemKeys.check([keycode], on: context.device)
        if let duration {
            let composite = InputEvent.composite([
                .keyboard(direction: .down, keyCode: UInt32(keycode)),
                .delay(duration),
                .keyboard(direction: .up, keyCode: UInt32(keycode))
            ])
            return [.hidMergeable(composite)]
        }

        return [.hidMergeable(.shortKeyPress(UInt32(keycode)))]
    }
}

extension KeySequence: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let parsedKeycodes = try parseCommaSeparatedIntsStrict(keycodesString, fieldName: "keycodes")
        try systemKeys.check(parsedKeycodes, on: context.device)
        let keyDelay = delay ?? 0.1
        var events: [InputEvent] = []

        for (index, keycode) in parsedKeycodes.enumerated() {
            events.append(.shortKeyPress(UInt32(keycode)))
            if index < parsedKeycodes.count - 1 && keyDelay > 0 {
                events.append(.delay(keyDelay))
            }
        }

        return [.hidMergeable(InputEvent.composite(events))]
    }
}

extension KeyCombo: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let parsedModifiers = try parseCommaSeparatedIntsStrict(modifiersString, fieldName: "modifier keycodes")
        try systemKeys.check(parsedModifiers + [key], on: context.device)

        var events: [InputEvent] = []
        for modifier in parsedModifiers {
            events.append(.keyboard(direction: .down, keyCode: UInt32(modifier)))
        }
        events.append(.shortKeyPress(UInt32(key)))
        for modifier in parsedModifiers.reversed() {
            events.append(.keyboard(direction: .up, keyCode: UInt32(modifier)))
        }

        return [.hidMergeable(InputEvent.composite(events))]
    }
}

extension Type: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let typed = try await typingPrimitives(context: context)
        // A step's text sits in the batch's steps, so it never goes into a password field, whatever its source.
        let clearing = text?.isEmpty == true
        let refusal = typed.isEmpty || clearing ? nil : Type.secureFieldRefusal(device: context.device, batch: true)
        guard intoQuery != nil || requireFocusID != nil else {
            let simulator = context.device.platform == .ios && !context.device.isPhysicalIOSDevice
            guard let refusal, !simulator else { return typed }
            let check = BatchPrimitive.run { _ in
                if (try? await context.accessibilityTree())?.secureFocus == .secureFocused { throw refusal }
            }
            return [check] + typed
        }
        let focus = BatchPrimitive.run { session in
            try await ensureFocus(backend: context.backend, device: context.device, logger: logger, refusingSecureTarget: refusal) { event in
                try await session.perform(event)
            }
            context.invalidateTree(sentInput: DispatchTracker.current.state != .no)
        }
        return [focus] + typed
    }

    private func typingPrimitives(context: BatchContext) async throws -> [BatchPrimitive] {
        let inputText = try resolvedText()

        if context.device.platform == .android || context.device.isPhysicalIOSDevice {
            if replace {
                return [.text(inputText, replace: true)]
            }
            return inputText.isEmpty ? [] : [.text(inputText, replace: false)]
        }

        try TextToHIDEvents.checkSupported(inputText)

        let hidEvents = try TextToHIDEvents.convertTextToHIDEvents(inputText)
        let clear = replace ? InputEvent.selectAllAndDelete(modifier: InputEvent.commandKey, settle: InputEvent.iosClearSettle) : nil
        guard !hidEvents.isEmpty || clear != nil else {
            return []
        }

        switch context.typeSubmissionMode {
        case .composite:
            return [.hidMergeable(InputEvent.composite((clear.map { [$0] } ?? []) + hidEvents))]
        case .chunked:
            let chunkSize = max(1, context.typeChunkSize)
            var primitives: [BatchPrimitive] = clear.map { [.hidBarrier($0)] } ?? []
            var start = 0
            while start < hidEvents.count {
                let end = min(start + chunkSize, hidEvents.count)
                let chunkEvents = Array(hidEvents[start..<end])
                primitives.append(.hidBarrier(InputEvent.composite(chunkEvents)))
                start = end
            }
            return primitives
        }
    }
}

extension RNDevMenu: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        guard item != nil || label != nil else { throw ValidationError(BatchStepParser.rnStepMessage) }
        return [.run { session in
            if context.device.platform == .android {
                _ = try await perform(on: context.route, clock: .live) { event in try await session.perform(event) }
            } else {
                _ = try await perform(on: context.route, clock: .live)
            }
        }]
    }
}
