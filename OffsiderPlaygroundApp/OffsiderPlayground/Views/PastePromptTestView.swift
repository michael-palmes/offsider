import SwiftUI
import UIKit

/// A control that reads the pasteboard on the main thread, as a paste button does, so iOS can ask the person before the read returns.
struct PastePromptTestView: View {
    @State private var state = "Clipboard: Not read"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Paste Prompt Playground")
                .font(.title2)
                .fontWeight(.bold)

            Button("Read Clipboard") {
                state = UIPasteboard.general.string == nil ? "Clipboard: Empty" : "Clipboard: Read"
            }
            .accessibilityIdentifier("paste-prompt-test-read")

            Text(state)
                .accessibilityIdentifier("paste-prompt-test-state")
                .accessibilityValue(state)

            Spacer()
        }
        .padding()
        .navigationTitle("Paste Prompt")
        .navigationBarTitleDisplayMode(.inline)
    }
}
