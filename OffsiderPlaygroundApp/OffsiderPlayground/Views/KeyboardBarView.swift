import SwiftUI

/// Fields for the bar iOS draws above the keys: one that gets suggestions and one that gets none. A tap on empty space closes the keyboard; with `toolbar` only the app's own Done bar does.
struct KeyboardBarView: View {
    var toolbar = false
    @State private var suggest = ""
    @State private var plain = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Keyboard Bar")
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityIdentifier("keyboard-bar-title")
            TextField("Suggestions on", text: $suggest)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($focused)
                .accessibilityIdentifier("keyboard-suggest-field")
            TextField("Suggestions off", text: $plain)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .accessibilityIdentifier("keyboard-plain-field")
            Text(toolbar ? "Done closes the keyboard" : "A tap on empty space closes the keyboard")
                .foregroundColor(.secondary)
                .accessibilityIdentifier("keyboard-bar-note")
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if !toolbar { focused = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard-bar-screen")
        .navigationTitle(toolbar ? "Keyboard Toolbar" : "Keyboard Bar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                        .accessibilityIdentifier("keyboard-toolbar-done")
                }
            }
        }
    }
}
