import AVFoundation
import AppTrackingTransparency
import CoreLocation
import SwiftUI
import UserNotifications

/// Raises the system's own permission prompts, one per control, so tests can read and answer real ones.
struct PermissionPromptTestView: View {
    @State private var notifications = "unknown"
    @State private var camera = "unknown"
    @State private var location = "unknown"
    @State private var tracking = "unknown"
    @StateObject private var locator = Locator()

    var body: some View {
        VStack(spacing: 16) {
            readout("Notifications", notifications, id: "permission-prompt-notifications")
            readout("Camera", camera, id: "permission-prompt-camera")
            readout("Location", location, id: "permission-prompt-location")
            readout("Tracking", tracking, id: "permission-prompt-tracking")
            Button("Refresh", action: refresh)
                .accessibilityIdentifier("permission-prompt-refresh")
            Button("Ask for Notifications") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in later(refresh) }
            }
            .accessibilityIdentifier("permission-prompt-ask-notifications")
            Button("Ask for Camera") {
                AVCaptureDevice.requestAccess(for: .video) { _ in later(refresh) }
            }
            .accessibilityIdentifier("permission-prompt-ask-camera")
            Button("Ask for Location") {
                locator.ask(then: refresh)
            }
            .accessibilityIdentifier("permission-prompt-ask-location")
            Button("Ask for Tracking") {
                ATTrackingManager.requestTrackingAuthorization { _ in later(refresh) }
            }
            .accessibilityIdentifier("permission-prompt-ask-tracking")
            Button("Ask for Camera then Location") {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    later { locator.ask(then: refresh) }
                }
            }
            .accessibilityIdentifier("permission-prompt-ask-both")
            Spacer()
        }
        .padding()
        .onAppear(perform: refresh)
        .navigationTitle("Permission Prompt Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func readout(_ name: String, _ value: String, id: String) -> some View {
        Text("\(name): \(value)")
            .accessibilityIdentifier(id)
            .accessibilityValue(value)
    }

    private func later(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let name = Self.name(settings.authorizationStatus)
            later { notifications = name }
        }
        camera = Self.name(AVCaptureDevice.authorizationStatus(for: .video))
        location = Self.name(locator.status)
        tracking = Self.name(ATTrackingManager.trackingAuthorizationStatus)
    }

    private static func name(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "authorised"
        case .denied: return "denied"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorised"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when-in-use"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ status: ATTrackingManager.AuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorised"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }
}

/// Core Location answers through a delegate, which a SwiftUI view cannot be.
private final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var changed: (() -> Void)?

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    func ask(then changed: @escaping () -> Void) {
        self.changed = changed
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.changed?() }
    }
}
