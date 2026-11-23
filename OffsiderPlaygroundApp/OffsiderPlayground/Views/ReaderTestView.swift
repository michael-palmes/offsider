import SwiftUI
import UIKit

/// Shows whether the system says VoiceOver is running, a button that counts each activation, and a row only a screen reader user gets.
struct ReaderTestView: View {
    @State private var running = UIAccessibility.isVoiceOverRunning
    @State private var count = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("VoiceOver: \(running ? "on" : "off")")
                .accessibilityIdentifier("reader-test-status")
                .accessibilityValue(running ? "on" : "off")
            Text("Count: \(count)")
                .accessibilityIdentifier("reader-test-count")
                .accessibilityValue(String(count))
            Button("Count Up") { count += 1 }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reader-test-count-up")
            if running {
                Text("Reader Only Row")
                    .accessibilityIdentifier("reader-test-only-row")
            }
            Spacer()
        }
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            running = UIAccessibility.isVoiceOverRunning
        }
        .navigationTitle("Reader Test")
        .navigationBarTitleDisplayMode(.inline)
    }
}
