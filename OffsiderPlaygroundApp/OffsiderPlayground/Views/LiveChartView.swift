import SwiftUI

/// A page that stops loading while its chart keeps redrawing, as a live chart does: its groups move and resize for good.
struct LiveChartView: View {
    private static let tick: TimeInterval = 0.15
    private static let bars = 6

    var body: some View {
        VStack(spacing: 16) {
            Text("Market")
                .font(.title2)
                .accessibilityIdentifier("live-chart-title")
            TimelineView(.periodic(from: .now, by: Self.tick)) { timeline in
                chart(step: Int(timeline.date.timeIntervalSinceReferenceDate / Self.tick))
            }
            .frame(height: 320, alignment: .top)
            Button("Buy") {}
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("live-chart-buy")
            Spacer()
        }
        .padding()
        .navigationTitle("Live Chart")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chart(step: Int) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(0..<Self.bars, id: \.self) { bar in
                Rectangle()
                    .fill(.green)
                    .frame(width: 24, height: CGFloat(60 + (step * 7 + bar * 31) % 180))
                    .accessibilityElement()
                    .accessibilityLabel("Bar \(bar + 1)")
            }
        }
        .padding(.top, CGFloat(step % 40))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-chart")
    }
}
