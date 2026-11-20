import SwiftUI

/// A two-step sign-up form: an email step, then password and confirm fields with a show-password switch. The readout says whether the two match, never what they hold.
struct SignUpView: View {
    enum Step {
        case email
        case password
        case created
    }

    @State private var step = Step.email
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var showPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .email:
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("signup-email")
                Button("Next") { step = .password }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("signup-next")
            case .password:
                Text(email.isEmpty ? "No email" : "Email entered")
                    .accessibilityIdentifier("signup-email-state")
                field("Password", text: $password, id: "signup-password")
                field("Confirm password", text: $confirm, id: "signup-confirm")
                Toggle("Show password", isOn: $showPassword)
                    .accessibilityIdentifier("signup-show-password")
                Text(matchState)
                    .accessibilityIdentifier("signup-match")
                Button("Create account") { step = .created }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("signup-create")
            case .created:
                Text("Account created")
                    .accessibilityIdentifier("signup-result")
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Sign Up")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matchState: String {
        if password.isEmpty && confirm.isEmpty { return "Both empty" }
        if confirm.isEmpty { return "Confirm empty" }
        return password == confirm ? "Passwords match" : "Passwords differ"
    }

    @ViewBuilder
    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        Group {
            if showPassword {
                TextField(title, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(title, text: text)
                    .textContentType(.newPassword)
            }
        }
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(id)
    }
}
