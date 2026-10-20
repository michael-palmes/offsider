import Foundation

/// What `unlock-code` shows a person: the banner over the prompt, and a page for what it saved, found or removed.
public enum UnlockCodeScreen {
    public static let codeLabel = "🔑 PIN or password"
    public static let againLabel = "🔁 Once more"

    public static func header(name: String, width: Int, style: TerminalStyle) -> [String] {
        TerminalUI.banner("Save the unlock code for \(name)", mark: .lock, width: width, style: style) + [""]
    }

    public static func codeProblem(_ code: String) -> String? {
        UnlockCode(code) == nil ? "❗ Use \(UnlockCode.lengths.lowerBound) to \(UnlockCode.lengths.upperBound) keyboard characters (a PIN is 4 to 16 digits)." : nil
    }

    public static func setCommand(_ device: String) -> String { "offsider unlock-code set --device \(device)" }

    /// `✅  Saved the unlock code for <name>`, then the command that types it.
    public static func saved(name: String, device: String) -> Page {
        Page([.outcome(.done("Saved the unlock code for \(name)"))], notices: [.next("offsider wake --unlock --device \(device)")])
    }

    /// The device and whether a code is saved; a code that failed last time is a warning naming the command that saves it again.
    public static func status(name: String, device: String, saved: Bool, lastAttemptFailed: Bool) -> Page {
        let fields = Block.fields([Field("Device", Table.Cell(name, untrusted: true)), Field("Unlock code", Table.Cell(saved ? "saved" : "none saved"))])
        guard saved else { return Page([fields], notices: [.next(setCommand(device))]) }
        guard lastAttemptFailed else { return Page([fields]) }
        return Page([fields], notices: [
            .warning("It failed last time, so Offsider won't type it until you unlock by hand or save it again", try: setCommand(device)),
        ])
    }

    public static func removed(name: String, removed: Bool) -> Page {
        guard removed else { return Page([.outcome(.done("Nothing to remove", details: ["no unlock code saved for \(name)"]))]) }
        return Page([.outcome(.done("Removed the unlock code for \(name)"))])
    }
}
