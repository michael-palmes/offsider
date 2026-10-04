import Contacts
import LocalAuthentication
import Photos
import SwiftUI

struct DeviceStateTestView: View {
    @State private var contacts = "unknown"
    @State private var photos = "unknown"
    @State private var biometry = "unknown"
    @State private var result = "none"

    var body: some View {
        VStack(spacing: 20) {
            Text("Contacts: \(contacts)")
                .accessibilityIdentifier("device-state-contacts")
                .accessibilityValue(contacts)
            Text("Photos: \(photos)")
                .accessibilityIdentifier("device-state-photos")
                .accessibilityValue(photos)
            Text("Biometry: \(biometry)")
                .accessibilityIdentifier("device-state-biometry")
                .accessibilityValue(biometry)
            Text("Biometric Result: \(result)")
                .accessibilityIdentifier("device-state-biometric-result")
                .accessibilityValue(result)
            Button("Refresh", action: refresh)
                .accessibilityIdentifier("device-state-refresh")
            Button("Authenticate", action: authenticate)
                .accessibilityIdentifier("device-state-authenticate")
            Spacer()
        }
        .padding()
        .onAppear(perform: refresh)
        .navigationTitle("Device State Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refresh() {
        contacts = Self.name(CNContactStore.authorizationStatus(for: .contacts))
        photos = Self.name(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometry = context.biometryType == .faceID ? "face" : context.biometryType == .touchID ? "finger" : "other"
        } else {
            biometry = "unavailable"
        }
    }

    private func authenticate() {
        result = "waiting"
        LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Offsider device state test") { success, error in
            let outcome = success ? "matched" : (error as? LAError)?.code == .authenticationFailed ? "failed" : "error"
            DispatchQueue.main.async { result = outcome }
        }
    }

    private static func name(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorised"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorised"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }
}
