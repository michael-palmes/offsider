import Foundation
import OffsiderCore

// MARK: - Text to HID Events Converter
struct TextToHIDEvents {
    
    // MARK: - Error Types
    enum TextConversionError: Error, LocalizedError, UserFacingError {
        /// One-based character positions, never the characters, so a secret never reaches an error or log.
        case unsupportedCharacters(positions: [Int], length: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedCharacters(let positions, let length):
                let subject = positions.count == 1
                    ? "The character at position \(positions[0]) (of \(length)) has"
                    : "Characters at positions \(Self.list(positions)) (of \(length)) have"
                return "\(subject) no US keyboard keycode. Only A-Z, a-z, 0-9 and US keyboard symbols can be typed."
            }
        }

        private static func list(_ positions: [Int]) -> String {
            let words = positions.map(String.init)
            guard words.count > 1 else { return words.joined() }
            return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }

        var userFacingDescription: String {
            errorDescription ?? "Offsider could not convert the requested text into simulator keyboard input."
        }
    }
    
    // MARK: - Simple Key Event Creation
    
    /// Creates key events for a character that doesn't require shift
    private static func simpleKeyEvent(keyCode: Int) -> [InputEvent] {
        return [
            .keyboard(direction: .down, keyCode: UInt32(keyCode)),
            .keyboard(direction: .up, keyCode: UInt32(keyCode))
        ]
    }
    
    /// Creates key events for a character that requires shift
    private static func shiftedKeyEvent(keyCode: Int) -> [InputEvent] {
        return [
            .keyboard(direction: .down, keyCode: 225),
            .keyboard(direction: .down, keyCode: UInt32(keyCode)),
            .keyboard(direction: .up, keyCode: UInt32(keyCode)),
            .keyboard(direction: .up, keyCode: 225)
        ]
    }
    
    // MARK: - Character to HID Event Mapping
    
    /// Converts a single supported character to its corresponding HID events
    private static func eventsForCharacter(_ character: Character) -> [InputEvent] {
        let keyEvent = KeyEvent.keyCodeForString(String(character))
        if keyEvent.shift {
            return shiftedKeyEvent(keyCode: keyEvent.keyCode)
        } else {
            return simpleKeyEvent(keyCode: keyEvent.keyCode)
        }
    }
    
    // MARK: - Public API
    
    /// Validates that a text string can be converted to HID events
    /// - Parameter text: The text string to validate
    /// - Returns: true if all characters are supported, false otherwise
    static func validateText(_ text: String) -> Bool {
        unsupportedPositions(in: text).isEmpty
    }

    /// One-based positions of the characters with no US keyboard keycode.
    static func unsupportedPositions(in text: String) -> [Int] {
        text.enumerated().compactMap { offset, character in
            KeyEvent.keyCodeForString(String(character)).keyCode == 0 ? offset + 1 : nil
        }
    }

    /// Throws `unsupportedCharacters` naming positions only.
    static func checkSupported(_ text: String) throws {
        let positions = unsupportedPositions(in: text)
        guard positions.isEmpty else {
            throw TextConversionError.unsupportedCharacters(positions: positions, length: text.count)
        }
    }
    
    /// Converts a text string to a sequence of HID events
    /// - Parameter text: The text string to convert
    /// - Returns: An array of InputEvent values representing the key presses
    /// - Throws: TextConversionError.unsupportedCharacters if any character is not supported
    static func convertTextToHIDEvents(_ text: String) throws -> [InputEvent] {
        try checkSupported(text)
        return text.flatMap(eventsForCharacter)
    }
}
