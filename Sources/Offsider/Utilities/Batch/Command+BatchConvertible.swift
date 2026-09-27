import ArgumentParser
import Foundation
import OffsiderCore

@MainActor
protocol BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive]
}

private func resolveBatchTapPoint(
    query: AccessibilityQuery,
    context: BatchContext,
    elementType: String?,
    logger: OffsiderLogger
) async throws -> (resolution: TapResolution, tree: UITree?) {
    var isFirstFetch = true
    var latestTree: UITree?
    let resolution = try await AccessibilityPoller.pollForResolution(
        query: query,
        waitTimeout: context.waitTimeout,
        pollInterval: context.pollInterval,
        elementType: elementType,
        logger: logger
    ) {
        let forceRefresh = !isFirstFetch
        isFirstFetch = false
        let tree = try await context.accessibilityTree(forceRefresh: forceRefresh)
        latestTree = tree
        return tree
    }
    return (resolution, latestTree)
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
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else if let elementValue {
                query = .value(elementValue)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            let resolved = try await resolveBatchTapPoint(
                query: query,
                context: context,
                elementType: elementType,
                logger: logger
            )
            resolution = resolved.resolution
            resolvedTree = resolved.tree
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
            throw CLIError(errorDescription: "Unexpected tap style resolution.")
        }
    }
}

extension Swipe: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0
        let physicalPoints = try await context.backend.deviceCoordinates(
            for: [(x: startX, y: startY), (x: endX, y: endY)],
            tree: nil,
            on: context.device
        )
        let physicalStart = physicalPoints[0]
        let physicalEnd = physicalPoints[1]

        let swipeEvent = InputEvent.swipe(
            physicalStart.x,
            yStart: physicalStart.y,
            xEnd: physicalEnd.x,
            yEnd: physicalEnd.y,
            delta: swipeDelta,
            duration: swipeDuration
        )
        return [.hidMergeable(InputEvent.delayed(swipeEvent, pre: preDelay, post: postDelay))]
    }
}

extension Gesture: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let width = screenWidth ?? 390.0
        let height = screenHeight ?? 844.0
        let coords = preset.coordinates(screenWidth: width, screenHeight: height)
        let gestureDuration = duration ?? preset.defaultDuration
        let gestureDelta = delta ?? preset.defaultDelta

        let gestureEvent = InputEvent.swipe(
            coords.startX,
            yStart: coords.startY,
            xEnd: coords.endX,
            yEnd: coords.endY,
            delta: gestureDelta,
            duration: gestureDuration
        )

        return [.hidMergeable(InputEvent.delayed(gestureEvent, pre: preDelay, post: postDelay))]
    }
}

extension Touch: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
        let physicalPoint = try await context.backend.deviceCoordinates(
            for: [(x: pointX, y: pointY)],
            tree: nil,
            on: context.device
        )[0]

        let touchDownEvent = InputEvent.touch(direction: .down, x: physicalPoint.x, y: physicalPoint.y)
        let touchUpEvent = InputEvent.touch(direction: .up, x: physicalPoint.x, y: physicalPoint.y)

        if touchDown && touchUp {
            let holdDelay = delay ?? TapTiming.defaultHoldDuration
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
        if let duration {
            let composite = InputEvent.composite([
                .button(direction: .down, button: buttonType.hardwareButton),
                .delay(duration),
                .button(direction: .up, button: buttonType.hardwareButton)
            ])
            return [.hidMergeable(composite)]
        }

        return [.hidMergeable(.shortButtonPress(buttonType.hardwareButton))]
    }
}

extension Key: BatchConvertible {
    func toBatchPrimitives(context: BatchContext, logger: OffsiderLogger) async throws -> [BatchPrimitive] {
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
        let inputText: String
        switch (text, useStdin, inputFile) {
        case (let positionalText?, false, nil):
            inputText = positionalText
        case (nil, true, nil):
            inputText = readFromStdin()
        case (nil, false, let file?):
            inputText = try readFromFile(file)
        default:
            throw CLIError(errorDescription: "Invalid input configuration.")
        }

        guard TextToHIDEvents.validateText(inputText) else {
            let unsupportedChars = inputText.compactMap { char in
                let keyEvent = KeyEvent.keyCodeForString(String(char))
                return keyEvent.keyCode == 0 ? char : nil
            }
            throw TextToHIDEvents.TextConversionError.unsupportedCharacter(unsupportedChars.first ?? " ")
        }

        let hidEvents = try TextToHIDEvents.convertTextToHIDEvents(inputText)
        guard !hidEvents.isEmpty else {
            return []
        }

        switch context.typeSubmissionMode {
        case .composite:
            return [.hidMergeable(InputEvent.composite(hidEvents))]
        case .chunked:
            let chunkSize = max(1, context.typeChunkSize)
            var primitives: [BatchPrimitive] = []
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
