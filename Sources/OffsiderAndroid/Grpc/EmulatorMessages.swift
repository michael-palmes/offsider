import Foundation

/// Offsider's values as proto messages and back; pure, so the wire shape is tested without an emulator.
extension EmulatorControlClient {
    static func touchEvent(_ touch: PanelTouch) -> Android_Emulation_Control_TouchEvent {
        touchEvent([touch])
    }

    static func touchEvent(_ touches: [PanelTouch]) -> Android_Emulation_Control_TouchEvent {
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = touches.map { touch in
            var point = Android_Emulation_Control_Touch()
            point.x = touch.x
            point.y = touch.y
            point.identifier = touch.identifier
            point.pressure = touch.pressure
            return point
        }
        return event
    }

    static func keyboardEvent(_ event: EmulatorKeyEvent) -> Android_Emulation_Control_KeyboardEvent {
        var message = Android_Emulation_Control_KeyboardEvent()
        switch event {
        case let .usb(code, phase):
            message.codeType = .usb
            message.keyCode = Int32(bitPattern: code)
            message.eventType = eventType(phase)
        case let .evdev(code, phase):
            message.codeType = .evdev
            message.keyCode = Int32(bitPattern: code)
            message.eventType = eventType(phase)
        case let .w3c(key, phase):
            message.key = key
            message.eventType = eventType(phase)
        case .text(let text):
            message.text = text
        }
        return message
    }

    static func imageFormat(_ format: EmulatorImageFormat, fitting box: FrameBox?) -> Android_Emulation_Control_ImageFormat {
        var request = Android_Emulation_Control_ImageFormat()
        request.format = format == .png ? .png : .rgba8888
        if let box {
            request.width = UInt32(max(1, box.width))
            request.height = UInt32(max(1, box.height))
        }
        return request
    }

    /// Size and rotation come from `Image.format`, never the deprecated top-level fields; nil for an empty image.
    static func frame(from image: Android_Emulation_Control_Image) -> EmulatorFrame? {
        let width = Int(image.format.width)
        let height = Int(image.format.height)
        guard width > 0, height > 0, !image.image.isEmpty else { return nil }
        let format: EmulatorImageFormat
        switch image.format.format {
        case .png: format = .png
        case .rgba8888:
            guard image.image.count >= width * height * 4 else { return nil }
            format = .rgba8888
        default: return nil
        }
        return EmulatorFrame(
            format: format,
            width: width,
            height: height,
            emulatorRotation: min(3, max(0, image.format.rotation.rotation.rawValue)),
            sequence: image.seq,
            bytes: image.image,
            folded: folded(from: image.format)
        )
    }

    /// Only a rectangle with both sides set counts: an unfolded frame leaves the message empty or absent.
    static func folded(from format: Android_Emulation_Control_ImageFormat) -> FoldedRect? {
        guard format.hasFoldedDisplay else { return nil }
        let folded = format.foldedDisplay
        guard folded.width > 0, folded.height > 0 else { return nil }
        return FoldedRect(x: Int(folded.xOffset), y: Int(folded.yOffset), width: Int(folded.width), height: Int(folded.height))
    }

    static func postureMessage(_ posture: EmulatorPosture) -> Android_Emulation_Control_Posture {
        var message = Android_Emulation_Control_Posture()
        message.value = Android_Emulation_Control_Posture.PostureValue(rawValue: posture.rawValue) ?? .postureUnknown
        return message
    }

    static func posture(from message: Android_Emulation_Control_Posture) -> EmulatorPosture {
        EmulatorPosture(rawValue: message.value.rawValue) ?? .unknown
    }

    private static func eventType(_ phase: KeyPhase) -> Android_Emulation_Control_KeyboardEvent.KeyEventType {
        switch phase {
        case .down: return .keydown
        case .up: return .keyup
        case .press: return .keypress
        }
    }
}

/// Tries 127.0.0.1, then `[::1]` when nothing answers there, proving each with `getStatus` within 2 s.
struct GrpcEmulatorConnector: EmulatorConnecting {
    func connect(discovery: EmulatorDiscovery, auth: EmulatorAuth) async throws -> any EmulatorControlling {
        guard let port = discovery.grpcPort else { throw AndroidError.grpcUnavailable(port: 0) }
        var unavailable: AndroidError?
        for address in [EmulatorControlClient.Address.ipv4, .ipv6] {
            let client: EmulatorControlClient
            do {
                client = try EmulatorControlClient(address: address, port: port, discovery: discovery, auth: auth)
            } catch {
                throw AndroidError.grpcFailed(endpoint: "port \(port)", method: EmulatorMethod.getStatus.rawValue, detail: String(describing: error))
            }
            do {
                _ = try await client.status()
                return client
            } catch let error as AndroidError where error.kind == .grpcUnavailable {
                client.shutdown()
                unavailable = error
            } catch {
                client.shutdown()
                throw error
            }
        }
        throw unavailable ?? AndroidError.grpcUnavailable(port: port)
    }
}
