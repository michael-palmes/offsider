import Foundation

// MARK: - Error Types
protocol UserFacingError: Error, CustomStringConvertible {
    var userFacingDescription: String { get }
}

extension UserFacingError {
    var description: String {
        userFacingDescription
    }
}

struct CLIError: LocalizedError, UserFacingError {
    let userFacingDescription: String

    init(errorDescription: String) {
        userFacingDescription = errorDescription
    }

    static func deviceNotFound(id: String) -> CLIError {
        CLIError(
            errorDescription: "No device with ID \(id) was found. Run `offsider list-devices` to see available devices."
        )
    }

    var errorDescription: String? { userFacingDescription }
}
