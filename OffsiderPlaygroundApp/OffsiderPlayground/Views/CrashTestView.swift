import SwiftUI

/// Buttons that end the app: one crashes it, so the simulator writes a crash report, and one quits with no report.
struct CrashTestView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Crash Playground")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("crash-test-title")

            Button("Crash Now") {
                fatalError("Crash test")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("crash-now")

            Button("Quit Now") {
                exit(0)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("quit-now")

            Spacer()
        }
        .padding()
        .navigationTitle("Crash Test")
        .navigationBarTitleDisplayMode(.inline)
    }
}
