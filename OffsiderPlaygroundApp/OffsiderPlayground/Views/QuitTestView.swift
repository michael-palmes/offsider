import SwiftUI

/// A button that ends the app cleanly, so no crash report or "quit unexpectedly" dialog follows.
struct QuitTestView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Quit Playground")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("quit-test-title")

            Button("Quit Now") {
                exit(0)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("quit-now")

            Spacer()
        }
        .padding()
        .navigationTitle("Quit Test")
        .navigationBarTitleDisplayMode(.inline)
    }
}
