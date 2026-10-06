import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Emulator gRPC messages")
struct EmulatorMessagesTests {
    @Test("a USB key keeps the 0x07 page in the top half and its phase")
    func usbKey() {
        let message = EmulatorControlClient.keyboardEvent(.usb(0x07 << 16 | 4, .press))
        #expect(message.codeType == .usb)
        #expect(message.keyCode == 0x070004)
        #expect(message.eventType == .keypress)
        #expect(message.key.isEmpty && message.text.isEmpty)
    }

    @Test("buttons are W3C key values and text goes in the text field")
    func w3cAndText() {
        let home = EmulatorControlClient.keyboardEvent(.w3c("GoHome", .down))
        #expect(home.key == "GoHome" && home.eventType == .keydown)
        #expect(EmulatorControlClient.keyboardEvent(.text("hello")).text == "hello")
    }

    @Test("a touch is one contact with its pressure; zero pressure lifts it")
    func touch() {
        let event = EmulatorControlClient.touchEvent(PanelTouch(x: 365, y: 570, pressure: 0))
        #expect(event.touches.count == 1)
        #expect(event.touches[0].x == 365 && event.touches[0].y == 570 && event.touches[0].pressure == 0)
    }

    @Test("scaling asks for both sides of the box, since the emulator ignores one alone")
    func imageFormat() {
        let scaled = EmulatorControlClient.imageFormat(.rgba8888, fitting: FrameBox(width: 540, height: 1212))
        #expect(scaled.format == .rgba8888 && scaled.width == 540 && scaled.height == 1212)
        let full = EmulatorControlClient.imageFormat(.png, fitting: nil)
        #expect(full.width == 0 && full.height == 0)
    }

    @Test("a frame's size and rotation come from Image.format; empty or short images are nil")
    func frame() {
        var image = Android_Emulation_Control_Image()
        image.format.format = .rgba8888
        image.format.width = 3
        image.format.height = 2
        image.format.rotation.rotation = .reverseLandscape
        image.width = 99
        image.height = 99
        image.seq = 7
        image.image = Data(repeating: 1, count: 24)

        let frame = EmulatorControlClient.frame(from: image)
        #expect(frame == EmulatorFrame(format: .rgba8888, width: 3, height: 2, emulatorRotation: 3, sequence: 7, bytes: Data(repeating: 1, count: 24)))

        image.image = Data(repeating: 1, count: 23)
        #expect(EmulatorControlClient.frame(from: image) == nil)
        image.format.width = 0
        #expect(EmulatorControlClient.frame(from: image) == nil)
    }

    @Test("several fingers are one event with a contact each, keeping identifiers and pressure")
    func touches() {
        let event = EmulatorControlClient.touchEvent([PanelTouch(x: 10, y: 20, pressure: 1, identifier: 0), PanelTouch(x: 70, y: 20, pressure: 1, identifier: 1)])
        #expect(event.touches.map(\.identifier) == [0, 1])
        #expect(event.touches.map(\.x) == [10, 70])
        #expect(event.touches.allSatisfy { $0.pressure == 1 })
    }
}
