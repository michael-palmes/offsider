import Foundation

/// Which window has input focus and which activity the window manager counts as focused, from `dumpsys window`.
struct AndroidWindowFocus: Equatable, Sendable {
    /// The package that owns a system_server window, such as a save prompt or an error dialog.
    static let systemOwner = "android"

    /// One `dumpsys`; window titles stay on this Mac and are parsed only to find the focused one.
    static let readScript = "dumpsys window | grep -E '^ *(Window #[0-9]+ Window[{]|mOwnerUid=|mCurrentFocus=|mFocusedApp=)'"

    /// The focused window's title as the window manager lists it.
    var title: String
    /// The package the window manager says owns it; nil when it does not list that window.
    var owner: String?
    /// Each display's focused activity package, nulls left out.
    var focusedApps: [String]

    /// Whether this is the input method, which never counts as an app in front.
    var isInputMethod: Bool { title == "InputMethod" }

    /// `Window{hash u0 title}`'s title, an activity's window as `package/Class`; nil when no window has focus.
    static func parse(_ output: String) -> AndroidWindowFocus? {
        var focusedApps: [String] = []
        var focus: (hash: String, title: String)?
        var owners: [String: String] = [:]
        var listed: String?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.drop(while: { $0 == " " })
            if line.hasPrefix("mCurrentFocus=") {
                if focus == nil { focus = window(in: line) }
            } else if line.hasPrefix("mFocusedApp=") {
                if let component = AndroidForeground.component(String(line)), let package = component.split(separator: "/").first {
                    focusedApps.append(String(package))
                }
            } else if line.hasPrefix("Window #") {
                listed = window(in: line)?.hash
            } else if line.hasPrefix("mOwnerUid="), let hash = listed {
                owners[hash] = line.split(separator: " ").first { $0.hasPrefix("package=") }.map { String($0.dropFirst("package=".count)) }
                listed = nil
            }
        }
        guard let focus else { return nil }
        return AndroidWindowFocus(title: focus.title, owner: owners[focus.hash], focusedApps: focusedApps)
    }

    /// The hash and title of the first `Window{hash u0 title}` in `line`.
    private static func window(in line: Substring) -> (hash: String, title: String)? {
        guard let open = line.range(of: "Window{"), let close = line.range(of: "}", options: .backwards), open.upperBound < close.lowerBound else { return nil }
        let parts = line[open.upperBound..<close.lowerBound].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[1].hasPrefix("u") else { return nil }
        return (String(parts[0]), String(parts[2]))
    }
}
