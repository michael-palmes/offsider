import SwiftUI
import UIKit

struct SwitchTestView: View {
    @State private var swiftUIWeatherAlertsEnabled = false
    @State private var uiKitWeatherAlertsEnabled = false
    @State private var slowCommitOn = false
    @State private var slowCommitPresses = 0
    @State private var slowCommitState = "Slow Commit Alerts: Off, presses 0"

    /// How long the slow switch waits before it flips, as one that waits for a server would; longer than a verify window.
    static let slowCommitDelay: TimeInterval = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Switch Playground")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("switch-test-title")

            VStack(alignment: .leading, spacing: 8) {
                Toggle("SwiftUI Weather Alerts", isOn: $swiftUIWeatherAlertsEnabled)
                    .accessibilityIdentifier("swiftui-weather-alerts-switch")
                    .accessibilityLabel("SwiftUI Weather Alerts")

                Text("SwiftUI Weather Alerts: \(swiftUIWeatherAlertsEnabled ? "On" : "Off")")
                    .font(.headline)
                    .accessibilityIdentifier("swiftui-weather-alerts-state")
                    .accessibilityValue(swiftUIWeatherAlertsEnabled ? "On" : "Off")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("UIKit Weather Alerts")
                    Spacer()
                    UIKitSwitch(
                        isOn: $uiKitWeatherAlertsEnabled,
                        accessibilityIdentifier: "uikit-weather-alerts-switch",
                        accessibilityLabel: "UIKit Weather Alerts"
                    )
                    .frame(width: 60, height: 36)
                }

                Text("UIKit Weather Alerts: \(uiKitWeatherAlertsEnabled ? "On" : "Off")")
                    .font(.headline)
                    .accessibilityIdentifier("uikit-weather-alerts-state")
                    .accessibilityValue(uiKitWeatherAlertsEnabled ? "On" : "Off")
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Slow Commit Alerts", isOn: Binding(get: { slowCommitOn }, set: { _ in pressSlowCommit() }))
                    .accessibilityIdentifier("slow-commit-switch")
                    .accessibilityLabel("Slow Commit Alerts")

                Text(slowCommitState)
                    .font(.headline)
                    .accessibilityIdentifier("slow-commit-state")
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Switch Test")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("switch-test-screen")
    }

    /// Each press flips the switch only after the delay, and the readout names the presses so far, so a second press shows.
    private func pressSlowCommit() {
        slowCommitPresses += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slowCommitDelay) {
            slowCommitOn.toggle()
            slowCommitState = "Slow Commit Alerts: \(slowCommitOn ? "On" : "Off"), presses \(slowCommitPresses)"
        }
    }
}

private struct UIKitSwitch: UIViewRepresentable {
    @Binding var isOn: Bool
    let accessibilityIdentifier: String
    let accessibilityLabel: String

    func makeUIView(context: Context) -> UISwitch {
        let uiSwitch = UISwitch()
        uiSwitch.accessibilityIdentifier = accessibilityIdentifier
        uiSwitch.accessibilityLabel = accessibilityLabel
        uiSwitch.addTarget(
            context.coordinator,
            action: #selector(Coordinator.valueChanged(_:)),
            for: .valueChanged
        )
        return uiSwitch
    }

    func updateUIView(_ uiView: UISwitch, context: Context) {
        uiView.isOn = isOn
        uiView.accessibilityIdentifier = accessibilityIdentifier
        uiView.accessibilityLabel = accessibilityLabel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    final class Coordinator: NSObject {
        private let isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc func valueChanged(_ sender: UISwitch) {
            isOn.wrappedValue = sender.isOn
        }
    }
}

#Preview {
    NavigationStack {
        SwitchTestView()
    }
}
