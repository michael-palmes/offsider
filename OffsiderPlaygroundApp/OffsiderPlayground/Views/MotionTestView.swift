import SwiftUI

/// Toggles endless motion the accessibility tree cannot see, so only screenshots show it; the toggle count appears only on request.
struct MotionTestView: View {
    @State private var moving = false
    @State private var toggles = 0
    @State private var shownToggles: Int?

    var body: some View {
        VStack(spacing: 16) {
            Text("Motion Playground")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("motion-test-title")

            Button("Toggle Motion") {
                toggles += 1
                moving.toggle()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("motion-toggle")

            Button("Show Toggles") {
                shownToggles = toggles
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("motion-show-toggles")

            Text(shownToggles.map { "Toggles: \($0)" } ?? "Toggles: hidden")
                .font(.headline)
                .accessibilityIdentifier("motion-toggles")

            TimelineView(.animation(paused: !moving)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate / 6
                Rectangle()
                    .fill(Color(hue: phase - phase.rounded(.down), saturation: 0.8, brightness: 0.9))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .accessibilityHidden(true)

            Spacer()
        }
        .padding()
        .navigationTitle("Motion Test")
        .navigationBarTitleDisplayMode(.inline)
    }
}
