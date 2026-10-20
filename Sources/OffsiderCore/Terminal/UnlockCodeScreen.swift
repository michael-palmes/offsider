import Foundation

/// What `unlock-code` shows on a terminal.
public enum UnlockCodeScreen {
    public static let codeLabel = "🔑 PIN or password"
    public static let againLabel = "🔁 Once more"

    public static func header(name: String, width: Int, style: TerminalStyle) -> [String] {
        TerminalUI.banner("Save the unlock code for \(name)", mark: .lock, width: width, style: style) + [""]
    }

    public static func codeProblem(_ code: String) -> String? {
        UnlockCode(code) == nil ? "❗ Use \(UnlockCode.lengths.lowerBound) to \(UnlockCode.lengths.upperBound) keyboard characters (a PIN is 4 to 16 digits)." : nil
    }

    public static func saved(name: String, device: String, style: TerminalStyle) -> String {
        [style.green(style.bold("✅ Saved the unlock code for \(name)")), PromptScreen.nextStep("Next", command: "offsider wake --unlock --device \(device)", style: style)].joined(separator: "\n")
    }

    public static func status(name: String, device: String, saved: Bool, lastAttemptFailed: Bool, style: TerminalStyle) -> String {
        guard saved else {
            return [style.bold("🔐 No unlock code saved for \(name)"), PromptScreen.nextStep("Add one", command: "offsider unlock-code set --device \(device)", style: style)].joined(separator: "\n")
        }
        guard lastAttemptFailed else { return style.green(style.bold("✅ Unlock code saved for \(name)")) }
        return [
            style.yellow(style.bold("❗ Unlock code saved for \(name), but it failed last time")),
            "   " + style.dim("Offsider won't type it until you unlock by hand or save it again."),
            PromptScreen.nextStep("Save it again", command: "offsider unlock-code set --device \(device)", style: style),
        ].joined(separator: "\n")
    }

    public static func removed(name: String, removed: Bool, style: TerminalStyle) -> String {
        style.bold(removed ? "🧹 Removed the unlock code for \(name)" : "🤷 No unlock code saved for \(name)")
    }
}
